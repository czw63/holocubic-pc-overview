namespace PcBridgeServer
{
    using System;
    using System.Collections.Generic;
    using System.Drawing;
    using System.Drawing.Drawing2D;
    using System.Drawing.Imaging;
    using System.IO;
    using System.Net;
    using System.Net.Sockets;
    using System.Runtime.InteropServices;
    using System.Security.Cryptography;
    using System.Text;
    using System.Threading;

    public sealed class BridgeServer
    {
        private readonly int port;
        private TcpListener listener;
        private volatile bool running;
        private Thread acceptThread;
        private readonly object sync = new object();
        private readonly List<WsClient> clients = new List<WsClient>();
        private string stateJson = "{}";
        private string spectrumJson = "{\"type\":\"spectrum\",\"bins\":[]}";
        private byte[] spectrumBinary = new byte[32];
        private UdpClient udp;
        private int udpPort = 8090;
        private IPEndPoint udpBroadcast;
        private readonly Dictionary<IPAddress, int> udpTargetCounts =
            new Dictionary<IPAddress, int>();
        private byte[] coverData;
        private string coverVersion = "";
        private PcBridgeAudio.LoopbackSpectrum audio;
        private string lastError = "";
        private int lastSpectrumSentMs = -10000;
        private int spectrumSentCount = 0;
        private int spectrumLastSentMs = 0;
        private int udpSentCount = 0;

        public Action SaltMediaChanged;

        public BridgeServer(int port)
        {
            this.port = port > 0 ? port : 8088;
        }

        public string LastError
        {
            get { lock (sync) return lastError; }
        }

        public int ClientCount
        {
            get { lock (sync) return clients.Count; }
        }

        public bool AudioRunning
        {
            get { return audio != null && audio.Running; }
        }

        public int SpectrumSentCount
        {
            get { lock (sync) return spectrumSentCount; }
        }

        public int UdpSentCount
        {
            get { lock (sync) return udpSentCount; }
        }

        public void Start()
        {
            if (running) return;
            running = true;
            listener = new TcpListener(IPAddress.Any, port);
            listener.Start();
            acceptThread = new Thread(AcceptLoop);
            acceptThread.IsBackground = true;
            acceptThread.Name = "bridge-http";
            acceptThread.Start();
        }

        public void Stop()
        {
            running = false;
            try { if (listener != null) listener.Stop(); } catch { }
            if (udp != null)
            {
                try { udp.Close(); } catch { }
                udp = null;
            }
            List<WsClient> snapshot;
            lock (sync)
            {
                snapshot = new List<WsClient>(clients);
                clients.Clear();
            }
            foreach (WsClient client in snapshot)
            {
                try { client.Close(); } catch { }
            }
            if (audio != null)
            {
                try { audio.Stop(); } catch { }
            }
        }

        public void SetState(string json)
        {
            if (string.IsNullOrEmpty(json)) json = "{}";
            lock (sync) stateJson = json;
            Broadcast(json);
        }

        public void SetSpectrum(double[] bins)
        {
            string json = BuildSpectrumJson(bins);
            byte[] binary = BuildSpectrumBinary(bins);
            bool send = false;
            int now = Environment.TickCount;
            lock (sync)
            {
                spectrumJson = json;
                spectrumBinary = binary;
                if (now - lastSpectrumSentMs >= 20)
                {
                    lastSpectrumSentMs = now;
                    spectrumSentCount++;
                    spectrumLastSentMs = now;
                    send = true;
                }
            }
            if (send)
            {
                SendSpectrumUdp(binary);
                BroadcastBinary(binary);
            }
        }

        public void SetCover(byte[] data, string version)
        {
            lock (sync)
            {
                coverData = data;
                coverVersion = version ?? "";
            }
        }

        public void SetCoverJpeg(byte[] imageBytes, string version, int size)
        {
            if (imageBytes == null || imageBytes.Length == 0 || size <= 0)
            {
                SetCover(null, version);
                return;
            }
            try
            {
                using (MemoryStream ms = new MemoryStream(imageBytes))
                using (Bitmap source = new Bitmap(ms))
                using (Bitmap target = new Bitmap(size, size))
                {
                    using (Graphics g = Graphics.FromImage(target))
                    {
                        g.Clear(Color.Black);
                        g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                        g.SmoothingMode = SmoothingMode.HighQuality;
                        g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                        g.DrawImage(source, 0, 0, size, size);
                    }

                    BitmapData bd = target.LockBits(new Rectangle(0, 0, size, size),
                        ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
                    byte[] argb = new byte[bd.Stride * size];
                    Marshal.Copy(bd.Scan0, argb, 0, argb.Length);
                    target.UnlockBits(bd);

                    byte[] rgb = new byte[size * size * 2];
                    for (int y = 0; y < size; y++)
                    {
                        int row = y * bd.Stride;
                        for (int x = 0; x < size; x++)
                        {
                            int idx = row + x * 4;
                            int b = argb[idx];
                            int gv = argb[idx + 1];
                            int r = argb[idx + 2];
                            int value = ((r & 0xF8) << 8) | ((gv & 0xFC) << 3) | (b >> 3);
                            int outIdx = (y * size + x) * 2;
                            rgb[outIdx] = (byte)(value & 0xFF);
                            rgb[outIdx + 1] = (byte)((value >> 8) & 0xFF);
                        }
                    }
                    SetCover(rgb, version);
                }
            }
            catch
            {
                SetCover(null, version);
            }
        }

        public void StartSpectrum(int udpPort = 8090, int processId = 0, string processName = null)
        {
            this.udpPort = udpPort > 0 ? udpPort : 8090;
            try
            {
                udp = new UdpClient();
                udp.EnableBroadcast = true;
                udpBroadcast = new IPEndPoint(IPAddress.Broadcast, this.udpPort);
            }
            catch
            {
                udp = null;
                udpBroadcast = null;
            }
            try
            {
                audio = new PcBridgeAudio.LoopbackSpectrum(processId, processName);
                audio.OnSpectrum = delegate(double[] bins)
                {
                    SetSpectrum(bins);
                };
                audio.OnError = delegate(string message)
                {
                    lock (sync) lastError = message;
                };
                audio.Start();
            }
            catch (Exception ex)
            {
                lock (sync) lastError = ex.ToString();
            }
        }

        public void AddUdpTarget(IPAddress address)
        {
            if (address == null) return;
            lock (sync)
            {
                int count;
                if (!udpTargetCounts.TryGetValue(address, out count))
                {
                    count = 0;
                }
                udpTargetCounts[address] = count + 1;
            }
        }

        public void RemoveUdpTarget(IPAddress address)
        {
            if (address == null) return;
            lock (sync)
            {
                int count;
                if (udpTargetCounts.TryGetValue(address, out count))
                {
                    count--;
                    if (count <= 0)
                    {
                        udpTargetCounts.Remove(address);
                    }
                    else
                    {
                        udpTargetCounts[address] = count;
                    }
                }
            }
        }

        private static string BuildSpectrumJson(double[] bins)
        {
            StringBuilder sb = new StringBuilder();
            sb.Append("{\"type\":\"spectrum\",\"bins\":[");
            if (bins != null)
            {
                for (int i = 0; i < bins.Length; i++)
                {
                    if (i > 0) sb.Append(",");
                    double value = Math.Round(Math.Max(0.0, Math.Min(1.0, bins[i])) * 1000.0) / 1000.0;
                    sb.Append(value.ToString("0.###", System.Globalization.CultureInfo.InvariantCulture));
                }
            }
            sb.Append("]}");
            return sb.ToString();
        }

        private static byte[] BuildSpectrumBinary(double[] bins)
        {
            byte[] data = new byte[32];
            if (bins != null)
            {
                int count = bins.Length < 32 ? bins.Length : 32;
                for (int i = 0; i < count; i++)
                {
                    double value = Math.Max(0.0, Math.Min(1.0, bins[i])) * 255.0;
                    data[i] = (byte)Math.Round(value);
                }
            }
            return data;
        }

        private void SendSpectrumUdp(byte[] data)
        {
            if (udp == null || data == null || data.Length == 0) return;
            IPEndPoint[] targets;
            lock (sync)
            {
                targets = new IPEndPoint[udpTargetCounts.Count];
                int index = 0;
                foreach (KeyValuePair<IPAddress, int> pair in udpTargetCounts)
                {
                    if (pair.Value > 0)
                    {
                        targets[index++] = new IPEndPoint(pair.Key, udpPort);
                    }
                }
            }
            if (targets.Length == 0)
            {
                if (udpBroadcast == null) return;
                try
                {
                    udp.Send(data, data.Length, udpBroadcast);
                    lock (sync) udpSentCount++;
                }
                catch
                {
                }
                return;
            }
            foreach (IPEndPoint target in targets)
            {
                if (target == null) continue;
                try
                {
                    udp.Send(data, data.Length, target);
                    lock (sync) udpSentCount++;
                }
                catch
                {
                }
            }
        }

        private void Broadcast(string json)
        {
            List<WsClient> snapshot;
            lock (sync)
            {
                snapshot = new List<WsClient>(clients);
            }
            foreach (WsClient client in snapshot)
            {
                try { client.SendText(json); }
                catch { RemoveClient(client); }
            }
        }

        private void BroadcastBinary(byte[] data)
        {
            List<WsClient> snapshot;
            lock (sync)
            {
                snapshot = new List<WsClient>(clients);
            }
            foreach (WsClient client in snapshot)
            {
                try { client.SendBinary(data); }
                catch { RemoveClient(client); }
            }
        }

        private void AcceptLoop()
        {
            while (running)
            {
                try
                {
                    TcpClient client = listener.AcceptTcpClient();
                    Thread handler = new Thread(delegate() { HandleClient(client); });
                    handler.IsBackground = true;
                    handler.Name = "bridge-client";
                    handler.Start();
                }
                catch
                {
                    Thread.Sleep(100);
                }
            }
        }

        private void HandleClient(TcpClient client)
        {
            try
            {
                client.ReceiveTimeout = 15000;
                NetworkStream stream = client.GetStream();
                string header = ReadHeader(stream);
                if (string.IsNullOrEmpty(header)) return;

                string[] lines = header.Split(new string[] { "\r\n" },
                    StringSplitOptions.RemoveEmptyEntries);
                string[] request = lines.Length > 0 ? lines[0].Split(' ') : new string[0];
                string method = request.Length > 0 ? request[0] : "";
                string path = request.Length > 1 ? request[1] : "/";
                string query = "";
                int q = path.IndexOf('?');
                if (q >= 0)
                {
                    query = path.Substring(q + 1);
                    path = path.Substring(0, q);
                }

                Dictionary<string, string> headers = ParseHeaders(lines);
                if (method == "GET" && path == "/ws")
                {
                IPAddress remoteAddress = null;
                try
                {
                    IPEndPoint remote = client.Client.RemoteEndPoint as IPEndPoint;
                    if (remote != null)
                    {
                        remoteAddress = remote.Address;
                    }
                }
                catch
                {
                }
                UpgradeToWebSocket(stream, headers, remoteAddress);
                }
                else
                {
                    ServeHttp(stream, method, path, query);
                }
            }
            catch
            {
            }
            finally
            {
                try { client.Close(); } catch { }
            }
        }

        private static string ReadHeader(NetworkStream stream)
        {
            byte[] buffer = new byte[4096];
            StringBuilder sb = new StringBuilder();
            while (sb.Length < 65536)
            {
                int n = stream.Read(buffer, 0, buffer.Length);
                if (n <= 0) break;
                sb.Append(Encoding.ASCII.GetString(buffer, 0, n));
                if (sb.ToString().IndexOf("\r\n\r\n", StringComparison.Ordinal) >= 0) break;
            }
            int end = sb.ToString().IndexOf("\r\n\r\n", StringComparison.Ordinal);
            if (end < 0) return "";
            return sb.ToString().Substring(0, end + 4);
        }

        private static Dictionary<string, string> ParseHeaders(string[] lines)
        {
            Dictionary<string, string> headers = new Dictionary<string, string>(
                StringComparer.OrdinalIgnoreCase);
            for (int i = 1; i < lines.Length; i++)
            {
                int colon = lines[i].IndexOf(':');
                if (colon <= 0) continue;
                string key = lines[i].Substring(0, colon).Trim();
                string value = lines[i].Substring(colon + 1).Trim();
                headers[key] = value;
            }
            return headers;
        }

        private void UpgradeToWebSocket(NetworkStream stream, Dictionary<string, string> headers,
            IPAddress remoteAddress)
        {
            string key = "";
            headers.TryGetValue("Sec-WebSocket-Key", out key);
            if (string.IsNullOrEmpty(key)) return;
            string accept;
            using (SHA1 sha = SHA1.Create())
            {
                byte[] hash = sha.ComputeHash(Encoding.ASCII.GetBytes(
                    key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"));
                accept = Convert.ToBase64String(hash);
            }
            string response = "HTTP/1.1 101 Switching Protocols\r\n" +
                "Upgrade: websocket\r\nConnection: Upgrade\r\n" +
                "Sec-WebSocket-Accept: " + accept + "\r\n\r\n";
            byte[] responseBytes = Encoding.ASCII.GetBytes(response);
            stream.Write(responseBytes, 0, responseBytes.Length);

            WsClient wsClient = new WsClient(stream);
            lock (sync) clients.Add(wsClient);
            if (remoteAddress != null) AddUdpTarget(remoteAddress);
            try
            {
                string state;
                byte[] binary;
                lock (sync)
                {
                    state = stateJson;
                    binary = spectrumBinary;
                }
                wsClient.SendText(state);
                wsClient.SendBinary(binary);
                wsClient.ReadLoop(delegate() { RemoveClient(wsClient); });
            }
            finally
            {
                if (remoteAddress != null) RemoveUdpTarget(remoteAddress);
                RemoveClient(wsClient);
            }
        }

        private void RemoveClient(WsClient client)
        {
            lock (sync)
            {
                clients.Remove(client);
            }
            try { client.Close(); } catch { }
        }

        private void ServeHttp(NetworkStream stream, string method, string path, string query)
        {
            if (method == "GET" && path == "/salt-media-changed")
            {
                Action action = SaltMediaChanged;
                if (action != null)
                {
                    try { action(); } catch { }
                }
                WriteText(stream, "200 OK", "application/json; charset=utf-8", "{\"ok\":true}");
                return;
            }
            if (method == "GET" && path == "/state")
            {
                string body;
                lock (sync) body = stateJson;
                WriteText(stream, "200 OK", "application/json; charset=utf-8", body);
                return;
            }
            if (method == "GET" && path == "/spectrum")
            {
                string body;
                lock (sync) body = spectrumJson;
                WriteText(stream, "200 OK", "application/json; charset=utf-8", body);
                return;
            }
            if (method == "GET" && path == "/cover")
            {
                byte[] data;
                string version;
                lock (sync)
                {
                    data = coverData;
                    version = coverVersion;
                }
                if (data == null || data.Length == 0)
                {
                    WriteText(stream, "404 Not Found", "text/plain; charset=utf-8", "no cover");
                    return;
                }
                WriteBytes(stream, "200 OK", "application/octet-stream", data,
                    "X-Cover-Version", version);
                return;
            }
            if (method == "GET" && path == "/cover64")
            {
                byte[] data;
                string version;
                lock (sync)
                {
                    data = coverData;
                    version = coverVersion;
                }
                if (data == null || data.Length == 0)
                {
                    WriteText(stream, "404 Not Found", "text/plain; charset=utf-8", "no cover");
                    return;
                }
                string body = "{\"ok\":true,\"version\":\"" + version + "\",\"data\":\"" +
                    Convert.ToBase64String(data) + "\"}";
                WriteText(stream, "200 OK", "application/json; charset=utf-8", body);
                return;
            }
            if (method == "GET" && path == "/health")
            {
                int count = ClientCount;
                int sent = SpectrumSentCount;
                int udpSent = UdpSentCount;
                bool audio = AudioRunning;
                string audioError = LastError;
                if (audioError != null && audioError.Length > 300)
                {
                    audioError = audioError.Substring(0, 300);
                }
                WriteText(stream, "200 OK", "application/json; charset=utf-8",
                    "{\"ok\":true,\"clients\":" + count.ToString(
                        System.Globalization.CultureInfo.InvariantCulture) +
                    ",\"spectrum_sent\":" + sent.ToString(
                        System.Globalization.CultureInfo.InvariantCulture) +
                    ",\"udp_sent\":" + udpSent.ToString(
                        System.Globalization.CultureInfo.InvariantCulture) +
                    ",\"audio\":" + (audio ? "true" : "false") +
                    ",\"audio_error\":\"" + (audioError ?? "").Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"}");
                return;
            }
            if (method == "GET" && (path == "/" || path == ""))
            {
                WriteText(stream, "200 OK", "text/html; charset=utf-8", IndexHtml);
                return;
            }
            WriteText(stream, "404 Not Found", "text/plain; charset=utf-8", "not found");
        }

        private static void WriteText(NetworkStream stream, string status, string contentType, string body)
        {
            WriteBytes(stream, status, contentType, Encoding.UTF8.GetBytes(body ?? ""), null, null);
        }

        private static void WriteBytes(NetworkStream stream, string status, string contentType,
            byte[] body, string extraHeader, string extraValue)
        {
            StringBuilder sb = new StringBuilder();
            sb.Append("HTTP/1.1 ").Append(status).Append("\r\n");
            sb.Append("Content-Type: ").Append(contentType).Append("\r\n");
            sb.Append("Content-Length: ").Append(body.Length.ToString(
                System.Globalization.CultureInfo.InvariantCulture)).Append("\r\n");
            sb.Append("Cache-Control: no-store\r\n");
            sb.Append("Access-Control-Allow-Origin: *\r\n");
            if (!string.IsNullOrEmpty(extraHeader))
            {
                sb.Append(extraHeader).Append(": ").Append(extraValue).Append("\r\n");
            }
            sb.Append("Connection: close\r\n\r\n");
            byte[] header = Encoding.ASCII.GetBytes(sb.ToString());
            stream.Write(header, 0, header.Length);
            stream.Write(body, 0, body.Length);
        }

        private const string IndexHtml = "<!doctype html><html><head><meta charset=\"utf-8\">" +
            "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">" +
            "<title>PC Overview Bridge</title><style>" +
            "body{background:#05070a;color:#f4f7fb;font:14px/1.5 sans-serif;margin:0;padding:24px}" +
            "main{max-width:860px;margin:0 auto}.grid{display:grid;grid-template-columns:1fr 1fr;gap:12px}" +
            "section{background:#101820;border:1px solid #1c2832;border-radius:8px;padding:14px}" +
            "h1,h2{margin:0 0 8px}code{background:#1c2832;padding:2px 6px;border-radius:4px}" +
            "canvas{width:100%;height:90px;background:#05070a;border:1px solid #1c2832;border-radius:6px}" +
            ".ok{color:#62e493}.err{color:#ff5d5d}@media(max-width:640px){.grid{grid-template-columns:1fr}}" +
            "</style></head><body><main><h1>PC Overview Bridge</h1><p id=\"status\" class=\"err\">connecting...</p>" +
            "<div class=\"grid\"><section><h2>Media</h2><p id=\"media\">-</p></section>" +
            "<section><h2>System</h2><p id=\"system\">-</p></section></div>" +
            "<section><h2>Spectrum</h2><canvas id=\"cv\" width=\"320\" height=\"80\"></canvas></section>" +
            "<script>" +
            "const cv=document.getElementById('cv'),g=cv.getContext('2d');let bins=[];" +
            "const ws=new WebSocket('ws://'+location.host+'/ws');" +
            "ws.onopen=()=>document.getElementById('status').className='ok',document.getElementById('status').textContent='connected';" +
            "ws.onclose=()=>{document.getElementById('status').textContent='closed';};" +
            "ws.onmessage=e=>{const d=JSON.parse(e.data);" +
            "if(d.type==='state'){document.getElementById('media').textContent=(d.title||'-')+' / '+(d.artist||'-')+' / '+(d.app||'-');" +
            "document.getElementById('system').textContent='CPU '+Math.round(d.cpu||0)+'% GPU '+Math.round(d.gpu||0)+'% RAM '+Math.round(d.mem||0)+'%';}" +
            "if(d.type==='spectrum'&&d.bins){bins=d.bins;draw();}};" +
            "function draw(){g.clearRect(0,0,320,80);const n=Math.min(bins.length,32),slot=320/n;" +
            "for(let i=0;i<n;i++){const h=Math.max(2,Math.round(bins[i]*76));" +
            "const c=i%2? '#35d0ba':'#62e493';g.fillStyle=c;g.fillRect(i*slot+1,80-h,slot-2,h);}}" +
            "setInterval(draw,100);</script></main></body></html>";

        private sealed class WsClient
        {
            private readonly NetworkStream stream;
            private readonly object writeSync = new object();

            public WsClient(NetworkStream stream)
            {
                this.stream = stream;
            }

            public void SendText(string text)
            {
                byte[] payload = Encoding.UTF8.GetBytes(text ?? "");
                byte[] frame = BuildFrame(0x1, payload);
                lock (writeSync)
                {
                    stream.Write(frame, 0, frame.Length);
                    stream.Flush();
                }
            }

            public void SendBinary(byte[] payload)
            {
                byte[] frame = BuildFrame(0x2, payload ?? new byte[0]);
                lock (writeSync)
                {
                    stream.Write(frame, 0, frame.Length);
                    stream.Flush();
                }
            }

            private static byte[] BuildFrame(int opcode, byte[] payload)
            {
                int headerLength = payload.Length < 126 ? 2 :
                    (payload.Length <= 65535 ? 4 : 10);
                byte[] frame = new byte[headerLength + payload.Length];
                frame[0] = (byte)(0x80 | opcode);
                if (payload.Length < 126)
                {
                    frame[1] = (byte)payload.Length;
                }
                else if (payload.Length <= 65535)
                {
                    frame[1] = 126;
                    frame[2] = (byte)(payload.Length >> 8);
                    frame[3] = (byte)(payload.Length & 0xFF);
                }
                else
                {
                    frame[1] = 127;
                    ulong len = (ulong)payload.Length;
                    for (int i = 0; i < 8; i++)
                    {
                        frame[2 + i] = (byte)(len >> ((7 - i) * 8));
                    }
                }
                Array.Copy(payload, 0, frame, headerLength, payload.Length);
                return frame;
            }

            public void ReadLoop(Action onClose)
            {
                byte[] header = new byte[2];
                while (true)
                {
                    if (!ReadExactly(header, 0, 2)) break;
                    int opcode = header[0] & 0x0F;
                    bool masked = (header[1] & 0x80) != 0;
                    long length = header[1] & 0x7F;
                    if (length == 126)
                    {
                        byte[] ext = new byte[2];
                        if (!ReadExactly(ext, 0, 2)) break;
                        length = (ext[0] << 8) | ext[1];
                    }
                    else if (length == 127)
                    {
                        byte[] ext = new byte[8];
                        if (!ReadExactly(ext, 0, 8)) break;
                        length = 0;
                        for (int i = 0; i < 8; i++)
                        {
                            length = (length << 8) | ext[i];
                        }
                    }
                    if (length < 0 || length > 1048576) break;
                    byte[] mask = new byte[4];
                    if (masked && !ReadExactly(mask, 0, 4)) break;
                    byte[] payload = new byte[length];
                    if (length > 0 && !ReadExactly(payload, 0, (int)length)) break;
                    if (masked)
                    {
                        for (int i = 0; i < payload.Length; i++)
                        {
                            payload[i] = (byte)(payload[i] ^ mask[i % 4]);
                        }
                    }
                    if (opcode == 0x8) break;
                    if (opcode == 0x9)
                    {
                        byte[] pong = BuildFrame(0xA, payload);
                        lock (writeSync)
                        {
                            stream.Write(pong, 0, pong.Length);
                            stream.Flush();
                        }
                    }
                }
                if (onClose != null) onClose();
            }

            private bool ReadExactly(byte[] buffer, int offset, int count)
            {
                int read = 0;
                while (read < count)
                {
                    int n = stream.Read(buffer, offset + read, count - read);
                    if (n <= 0) return false;
                    read += n;
                }
                return true;
            }

            public void Close()
            {
                try { stream.Close(); } catch { }
            }
        }
    }
}
