using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;

namespace PcBridgeAudio
{
    internal enum AudioClientShareMode
    {
        Shared = 0,
        Exclusive = 1
    }

    [Flags]
    internal enum AudioClientStreamFlags
    {
        None = 0,
        CrossProcess = 0x10000,
        Loopback = 0x20000,
        EventCallback = 0x40000,
        NoPersist = 0x80000
    }

    [Flags]
    internal enum AudioClientBufferFlags
    {
        None = 0,
        DataDiscontinuity = 1,
        Silent = 2,
        TimestampError = 4
    }

    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    public struct WaveFormatEx
    {
        public ushort wFormatTag;
        public ushort nChannels;
        public uint nSamplesPerSec;
        public uint nAvgBytesPerSec;
        public ushort nBlockAlign;
        public ushort wBitsPerSample;
        public ushort cbSize;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    public struct WaveFormatExtensible
    {
        public WaveFormatEx Format;
        public ushort wValidBitsPerSample;
        public uint dwChannelMask;
        public Guid SubFormat;
    }

    internal delegate void ApplicationLoopbackAudioCallback(
        IntPtr instance, IntPtr data, uint length);

    internal delegate void ApplicationLoopbackEvent(IntPtr instance);

    internal static class ApplicationLoopbackNative
    {
        [DllImport("ApplicationLoopback.dll", CallingConvention = CallingConvention.StdCall)]
        internal static extern IntPtr InitializeCapture(
            ushort channels, uint sampleRate, ushort bitsPerSample,
            ApplicationLoopbackAudioCallback callback, ApplicationLoopbackEvent audioCaptureStopped);

        [DllImport("ApplicationLoopback.dll", CallingConvention = CallingConvention.StdCall)]
        internal static extern int StartCaptureAsync(
            IntPtr capture, uint processId, bool includeProcessTree);

        [DllImport("ApplicationLoopback.dll", CallingConvention = CallingConvention.StdCall)]
        internal static extern int StopCaptureAsync(IntPtr capture);

        [DllImport("ApplicationLoopback.dll", CallingConvention = CallingConvention.StdCall)]
        internal static extern void FreeCapture(IntPtr capture);
    }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IMMDeviceEnumerator
    {
        [PreserveSig]
        int EnumAudioEndpoints(int dataFlow, int stateMask, out IMMDeviceCollection devices);

        [PreserveSig]
        int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice device);

        [PreserveSig]
        int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);

        [PreserveSig]
        int RegisterEndpointNotificationCallback(IntPtr callback);

        [PreserveSig]
        int UnregisterEndpointNotificationCallback(IntPtr callback);
    }

    [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IMMDeviceCollection
    {
        [PreserveSig]
        int GetCount(out uint count);

        [PreserveSig]
        int Item(uint index, out IMMDevice device);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IMMDevice
    {
        [PreserveSig]
        int Activate(ref Guid iid, int clsCtx, IntPtr activationParams,
            [MarshalAs(UnmanagedType.IUnknown)] out object interfacePointer);

        [PreserveSig]
        int OpenPropertyStore(int stgmAccess, out IntPtr properties);

        [PreserveSig]
        int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);

        [PreserveSig]
        int GetState(out int state);
    }

    [ComImport, Guid("1CB9AD4C-DBFA-4C32-B178-C2F568A703B2"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAudioClient
    {
        [PreserveSig]
        int Initialize(AudioClientShareMode shareMode, AudioClientStreamFlags streamFlags,
            long hnsBufferDuration, long hnsPeriodicity, ref WaveFormatExtensible format,
            ref Guid audioSessionGuid);

        [PreserveSig]
        int GetBufferSize(out uint bufferSize);

        [return: MarshalAs(UnmanagedType.I8)]
        long GetStreamLatency();

        [PreserveSig]
        int GetCurrentPadding(out int currentPadding);

        [PreserveSig]
        int IsFormatSupported(AudioClientShareMode shareMode, ref WaveFormatEx format,
            IntPtr closestMatchFormat);

        [PreserveSig]
        int GetMixFormat(out IntPtr deviceFormatPointer);

        [PreserveSig]
        int GetDevicePeriod(out long defaultDevicePeriod, out long minimumDevicePeriod);

        [PreserveSig]
        int Start();

        [PreserveSig]
        int Stop();

        [PreserveSig]
        int Reset();

        [PreserveSig]
        int SetEventHandle(IntPtr eventHandle);

        [PreserveSig]
        int GetService([In, MarshalAs(UnmanagedType.LPStruct)] Guid interfaceId,
            [Out, MarshalAs(UnmanagedType.IUnknown)] out object interfacePointer);
    }

    [ComImport, Guid("C8ADBD64-E71E-48A0-A4DE-185C395CD317"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAudioCaptureClient
    {
        [PreserveSig]
        int GetBuffer(out IntPtr dataBuffer, out int numFramesToRead,
            out AudioClientBufferFlags bufferFlags, out long devicePosition,
            out long qpcPosition);

        [PreserveSig]
        int ReleaseBuffer(int numFramesRead);

        [PreserveSig]
        int GetNextPacketSize(out int numFramesInNextPacket);
    }

    public sealed class LoopbackSpectrum
    {
        public Action<double[]> OnSpectrum;
        public Action<string> OnError;

        private const int FftSize = 1024;
        private const int BinCount = 32;
        private readonly int targetProcessId;
        private readonly string targetProcessName;
        private readonly ApplicationLoopbackAudioCallback processAudioDelegate;
        private readonly ApplicationLoopbackEvent processStoppedDelegate;
        private readonly object processLock = new object();
        private readonly AutoResetEvent processWait = new AutoResetEvent(false);
        private IntPtr processCapture;
        private double[] processFftBuffer = new double[FftSize];
        private int processPosition;
        private double[] processSmooth = new double[BinCount];
        private volatile bool running;
        private Thread thread;

        public LoopbackSpectrum(int processId = 0, string processName = null)
        {
            targetProcessId = processId;
            targetProcessName = processName;
            processAudioDelegate = OnProcessAudio;
            processStoppedDelegate = OnProcessStopped;
        }

        public bool Running
        {
            get { return running; }
        }

        public void Start()
        {
            if (running) return;
            running = true;
            thread = targetProcessId > 0 || !string.IsNullOrEmpty(targetProcessName)
                ? new Thread(ProcessWorker)
                : new Thread(Worker);
            thread.IsBackground = true;
            thread.Name = "loopback-spectrum";
            thread.Start();
        }

        public void Stop()
        {
            running = false;
            IntPtr capture;
            lock (processLock)
            {
                capture = processCapture;
                processCapture = IntPtr.Zero;
            }
            if (capture != IntPtr.Zero)
            {
                try { ApplicationLoopbackNative.StopCaptureAsync(capture); } catch { }
            }
            processWait.Set();
            if (thread != null && thread.IsAlive)
            {
                thread.Join(500);
            }
            thread = null;
        }

        private void ProcessWorker()
        {
            while (running)
            {
                int pid = ResolveProcessId();
                if (pid <= 0)
                {
                    if (OnError != null)
                    {
                        OnError("target process not found: " + (targetProcessName ?? targetProcessId.ToString()));
                    }
                    Thread.Sleep(2000);
                    continue;
                }

                IntPtr capture = IntPtr.Zero;
                try
                {
                    capture = ApplicationLoopbackNative.InitializeCapture(
                        2, 48000, 16, processAudioDelegate, processStoppedDelegate);
                    if (capture == IntPtr.Zero)
                    {
                        if (OnError != null) OnError("ApplicationLoopback init failed");
                        Thread.Sleep(2000);
                        continue;
                    }

                    lock (processLock) processCapture = capture;
                    int hr = ApplicationLoopbackNative.StartCaptureAsync(
                        capture, (uint)pid, true);
                    if (hr < 0)
                    {
                        if (OnError != null)
                        {
                            OnError("ApplicationLoopback start failed hr=0x" + hr.ToString("X8"));
                        }
                        lock (processLock) processCapture = IntPtr.Zero;
                        try { ApplicationLoopbackNative.FreeCapture(capture); } catch { }
                        Thread.Sleep(2000);
                        continue;
                    }

                    if (OnError != null) OnError("process loopback started pid=" + pid);
                    processWait.Reset();
                    while (running)
                    {
                        if (processWait.WaitOne(1000)) break;
                        if (!string.IsNullOrEmpty(targetProcessName) && !ProcessStillAlive(pid)) break;
                    }
                }
                catch (Exception ex)
                {
                    if (OnError != null) OnError(ex.Message);
                    Thread.Sleep(2000);
                }
                finally
                {
                    IntPtr cap;
                    lock (processLock)
                    {
                        cap = processCapture;
                        processCapture = IntPtr.Zero;
                    }
                    if (cap != IntPtr.Zero)
                    {
                        try { ApplicationLoopbackNative.FreeCapture(cap); } catch { }
                    }
                }
            }
        }

        private int ResolveProcessId()
        {
            if (targetProcessId > 0) return targetProcessId;
            if (string.IsNullOrEmpty(targetProcessName)) return 0;
            string name = targetProcessName;
            if (name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase))
            {
                name = name.Substring(0, name.Length - 4);
            }
            Process[] processes = Process.GetProcessesByName(name);
            try
            {
                return processes.Length > 0 ? processes[0].Id : 0;
            }
            finally
            {
                foreach (Process p in processes) p.Dispose();
            }
        }

        private static bool ProcessStillAlive(int pid)
        {
            try
            {
                using (Process p = Process.GetProcessById(pid))
                {
                    return true;
                }
            }
            catch
            {
                return false;
            }
        }

        private void OnProcessStopped(IntPtr instance)
        {
            processWait.Set();
        }

        private void OnProcessAudio(IntPtr instance, IntPtr data, uint length)
        {
            try
            {
                if (!running || data == IntPtr.Zero || length < 2) return;
                int sampleCount = (int)(length / 2);
                short[] samples = new short[sampleCount];
                Marshal.Copy(data, samples, 0, sampleCount);

                int i = 0;
                while (i + 1 < sampleCount)
                {
                    double left = samples[i] / 32768.0;
                    double right = samples[i + 1] / 32768.0;
                    processFftBuffer[processPosition++] = (left + right) * 0.5;
                    if (processPosition >= FftSize)
                    {
                        processSmooth = ComputeSpectrum(processFftBuffer, 48000, processSmooth);
                        int overlap = FftSize / 2;
                        for (int j = 0; j < overlap; j++)
                        {
                            processFftBuffer[j] = processFftBuffer[j + overlap];
                        }
                        processPosition = overlap;
                    }
                    i += 2;
                }
            }
            catch
            {
            }
        }

        private void Worker()
        {
            while (running)
            {
                List<IMMDevice> candidates = new List<IMMDevice>();
                try
                {
                    Type enumType = Type.GetTypeFromCLSID(
                        new Guid("BCDE0395-E52F-467C-8E3D-C4579291692E"));
                    if (enumType == null) throw new InvalidOperationException("MMDeviceEnumerator missing");

                    IMMDeviceEnumerator enumerator =
                        (IMMDeviceEnumerator)Activator.CreateInstance(enumType);
                    IMMDevice def;
                    if (enumerator.GetDefaultAudioEndpoint(0, 0, out def) == 0 && def != null)
                    {
                        candidates.Add(def);
                    }
                    IMMDeviceCollection collection;
                    if (enumerator.EnumAudioEndpoints(0, 0x0F, out collection) == 0)
                    {
                        uint count;
                        if (collection.GetCount(out count) == 0)
                        {
                            for (uint i = 0; i < count; i++)
                            {
                                IMMDevice dev;
                                if (collection.Item(i, out dev) == 0 && dev != null)
                                {
                                    candidates.Add(dev);
                                }
                            }
                        }
                    }
                }
                catch
                {
                }

                string lastError = "no audio device";
                bool opened = false;
                foreach (IMMDevice dev in candidates)
                {
                    if (!running) return;
                    IAudioClient client;
                    IAudioCaptureClient capture;
                    WaveFormatEx fmt;
                    bool floatFormat;
                    if (TryOpenDevice(dev, out client, out capture, out fmt, out floatFormat, out lastError))
                    {
                        opened = true;
                        CaptureLoop(client, capture, fmt, floatFormat);
                        return;
                    }
                }

                if (!opened)
                {
                    if (OnError != null) OnError(lastError);
                    Thread.Sleep(2000);
                }
            }
        }

        private bool TryOpenDevice(IMMDevice device, out IAudioClient client,
            out IAudioCaptureClient capture, out WaveFormatEx fmt, out bool floatFormat,
            out string error)
        {
            client = null;
            capture = null;
            fmt = new WaveFormatEx();
            floatFormat = false;
            error = "";
            try
            {
                Guid iidClient = new Guid("1CB9AD4C-DBFA-4C32-B178-C2F568A703B2");
                object clientObject;
                int hr = device.Activate(ref iidClient, 1, IntPtr.Zero, out clientObject);
                if (hr < 0) throw new Exception("Activate IAudioClient hr=0x" + hr.ToString("X8"));

                client = (IAudioClient)clientObject;
                IntPtr mixPtr;
                hr = client.GetMixFormat(out mixPtr);
                if (hr < 0) throw new Exception("GetMixFormat hr=0x" + hr.ToString("X8"));

                fmt = (WaveFormatEx)Marshal.PtrToStructure(mixPtr, typeof(WaveFormatEx));
                WaveFormatExtensible extFormat = new WaveFormatExtensible();
                extFormat.Format = fmt;
                floatFormat = fmt.wFormatTag == 3;
                if (fmt.wFormatTag == 0xFFFE)
                {
                    extFormat = (WaveFormatExtensible)Marshal.PtrToStructure(
                        mixPtr, typeof(WaveFormatExtensible));
                    WaveFormatEx extBase = extFormat.Format;
                    fmt.wFormatTag = extBase.wFormatTag;
                    fmt.nChannels = extBase.nChannels;
                    fmt.nSamplesPerSec = extBase.nSamplesPerSec;
                    fmt.nAvgBytesPerSec = extBase.nAvgBytesPerSec;
                    fmt.nBlockAlign = extBase.nBlockAlign;
                    fmt.wBitsPerSample = extBase.wBitsPerSample;
                    fmt.cbSize = extBase.cbSize;
                    Guid floatGuid = new Guid("00000003-0000-0010-8000-00AA00389B71");
                    floatFormat = extFormat.SubFormat == floatGuid;
                }

                Guid empty = Guid.Empty;
                hr = client.Initialize(AudioClientShareMode.Shared,
                    AudioClientStreamFlags.Loopback, 0L, 0L, ref extFormat, ref empty);
                if (hr < 0)
                {
                    throw new Exception("Initialize loopback hr=0x" + hr.ToString("X8") +
                        " tag=" + fmt.wFormatTag.ToString() +
                        " ch=" + fmt.nChannels.ToString() +
                        " sr=" + fmt.nSamplesPerSec.ToString() +
                        " bits=" + fmt.wBitsPerSample.ToString() +
                        " align=" + fmt.nBlockAlign.ToString());
                }

                Guid iidCapture = new Guid("C8ADBD64-E71E-48A0-A4DE-185C395CD317");
                object captureObject;
                hr = client.GetService(iidCapture, out captureObject);
                if (hr < 0) throw new Exception("GetService IAudioCaptureClient hr=0x" + hr.ToString("X8"));

                capture = (IAudioCaptureClient)captureObject;
                hr = client.Start();
                if (hr < 0) throw new Exception("IAudioClient.Start hr=0x" + hr.ToString("X8"));
                return true;
            }
            catch (Exception ex)
            {
                error = ex.ToString();
                return false;
            }
        }

        private void CaptureLoop(IAudioClient client, IAudioCaptureClient capture,
            WaveFormatEx fmt, bool floatFormat)
        {
            int bytesPerSample = fmt.wBitsPerSample / 8;
            if (bytesPerSample <= 0) bytesPerSample = 4;
            int blockAlign = fmt.nBlockAlign;
            if (blockAlign <= 0) blockAlign = fmt.nChannels * bytesPerSample;
            int channels = fmt.nChannels;
            if (channels <= 0) channels = 2;
            int sampleRate = (int)fmt.nSamplesPerSec;
            if (sampleRate <= 0) sampleRate = 48000;

            double[] fftBuffer = new double[FftSize];
            int position = 0;
            double[] smooth = new double[BinCount];
            int overlap = FftSize / 2;
            int idleMs = 0;

            while (running)
            {
                int next = 0;
                capture.GetNextPacketSize(out next);
                if (next > 0)
                {
                    idleMs = 0;
                    IntPtr ptr;
                    int frames;
                    AudioClientBufferFlags flags;
                    long devicePosition, qpcPosition;
                    int hr = capture.GetBuffer(out ptr, out frames, out flags,
                        out devicePosition, out qpcPosition);
                    if (hr == 0 && frames > 0)
                    {
                        byte[] bytes = new byte[frames * blockAlign];
                        Marshal.Copy(ptr, bytes, 0, bytes.Length);
                        for (int i = 0; i < frames && running; i++)
                        {
                            double sum = 0.0;
                            for (int ch = 0; ch < channels; ch++)
                            {
                                int offset = i * blockAlign + ch * bytesPerSample;
                                double value = 0.0;
                                if (floatFormat && bytesPerSample >= 4)
                                {
                                    value = BitConverter.ToSingle(bytes, offset);
                                }
                                else if (bytesPerSample == 2)
                                {
                                    value = BitConverter.ToInt16(bytes, offset) / 32768.0;
                                }
                                else if (bytesPerSample >= 4)
                                {
                                    value = BitConverter.ToInt32(bytes, offset) / 2147483648.0;
                                }
                                sum += value;
                            }
                            fftBuffer[position++] = sum / channels;
                            if (position >= FftSize)
                            {
                                smooth = ComputeSpectrum(fftBuffer, sampleRate, smooth);
                                for (int j = 0; j < overlap; j++)
                                {
                                    fftBuffer[j] = fftBuffer[j + overlap];
                                }
                                position = overlap;
                            }
                        }
                        capture.ReleaseBuffer(frames);
                    }
                }
                else
                {
                    idleMs += 5;
                    if (idleMs >= 100)
                    {
                        idleMs = 0;
                        if (OnSpectrum != null)
                        {
                            OnSpectrum(new double[BinCount]);
                        }
                    }
                }
                Thread.Sleep(5);
            }

            try { client.Stop(); } catch { }
        }

        private double[] ComputeSpectrum(double[] samples, int sampleRate, double[] smooth)
        {
            double minFreq = 60.0;
            double maxFreq = 16000.0;
            double[] powers = new double[BinCount];

            for (int b = 0; b < BinCount; b++)
            {
                double ratio = (double)b / (double)(BinCount - 1);
                double freq = minFreq * Math.Pow(maxFreq / minFreq, ratio);
                double omega = 2.0 * Math.PI * freq / sampleRate;
                double coeff = 2.0 * Math.Cos(omega);
                double s0 = 0.0, s1 = 0.0, s2 = 0.0;
                for (int n = 0; n < samples.Length; n++)
                {
                    s0 = samples[n] + coeff * s1 - s2;
                    s2 = s1;
                    s1 = s0;
                }
                double power = s1 * s1 + s2 * s2 - coeff * s1 * s2;
                if (power < 0) power = 0;
                powers[b] = Math.Sqrt(power) / samples.Length;
            }

            double rms = 0.0;
            for (int n = 0; n < samples.Length; n++)
            {
                rms += samples[n] * samples[n];
            }
            rms = Math.Sqrt(rms / samples.Length);
            double peak = 0.0;
            for (int b = 0; b < BinCount; b++)
            {
                if (powers[b] > peak) peak = powers[b];
            }
            double norm = Math.Max(Math.Max(peak * 0.85, rms * 1.2), 0.00002);

            double[] result = new double[BinCount];
            for (int b = 0; b < BinCount; b++)
            {
                double raw = powers[b] / norm;
                if (raw > 1.0) raw = 1.0;
                raw = Math.Pow(raw, 0.65);
                result[b] = smooth[b] * 0.3 + raw * 0.7;
                if (result[b] > 1.0) result[b] = 1.0;
            }

            if (OnSpectrum != null) OnSpectrum(result);
            return result;
        }
    }
}
