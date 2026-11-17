// P1.4b measurement helper (C# 5, compiled in-process by Add-Type from the benchmark helper).
//
// WHY THIS EXISTS: PowerShell script blocks cannot run on a thread-pool thread without a runspace, so an
// asynchronous continuation written in PowerShell cannot take a timestamp at the moment the HTTP body is complete.
// The main collection loop only observes task completion later, which is exactly the ambiguity P1.4b has to remove.
// This class performs the request itself and takes the timestamp in its own continuation, immediately after the
// complete body bytes are in the client's memory.
//
// WHAT THE MARK IS: the point at which the client holds the COMPLETE response body. It is NOT the server's service
// time and NOT the last TCP byte; it includes the client-side completion continuation and thread-pool scheduling.
// The private observer/loop-stall controls in this card bound that scheduling delay, and the wording is repeated in
// every stats block so the number can never be read as a server measurement.
//
// The clock is System.Diagnostics.Stopwatch.GetTimestamp() with Stopwatch.Frequency. That is the SAME monotonic
// source the collector's own Stopwatch uses, and it is machine-wide, so the observer process reports on the same axis.
using System;
using System.Diagnostics;
using System.Net.Http;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace P14b
{
    public sealed class HitResult
    {
        public long DispatchTicks;
        public long BodyReadyTicks;      // 0 when no complete body was obtained
        public long CompletedTicks;      // the moment the helper's task returned to the caller's thread
        public int StatusCode = -1;
        public byte[] Body;
        public string Headers = "";
        public string Error = "";
        public bool TimedOut;
        public string BodyState = "unavailable";
    }

    public static class Hit
    {
        // monotonic milliseconds on the shared axis (milliseconds since an unspecified machine-wide origin)
        public static double MonoMs(long ticks)
        {
            return ticks * 1000.0 / (double)Stopwatch.Frequency;
        }

        public static long NowTicks()
        {
            return Stopwatch.GetTimestamp();
        }

        public static long Frequency()
        {
            return Stopwatch.Frequency;
        }

        private static string RenderHeaders(HttpResponseMessage resp)
        {
            try
            {
                StringBuilder sb = new StringBuilder();
                foreach (var h in resp.Headers)
                {
                    if (sb.Length > 0) sb.Append(" | ");
                    sb.Append(h.Key).Append(": ").Append(string.Join(",", h.Value));
                }
                if (resp.Content != null)
                {
                    foreach (var h in resp.Content.Headers)
                    {
                        if (sb.Length > 0) sb.Append(" | ");
                        sb.Append(h.Key).Append(": ").Append(string.Join(",", h.Value));
                    }
                }
                return sb.ToString();
            }
            catch (Exception ex)
            {
                return "unavailable: " + ex.Message;
            }
        }

        // One GET with the complete body read inside this class. The dispatch stamp is taken immediately before
        // SendAsync; the body-ready stamp immediately after the complete byte array is available.
        public static async Task<HitResult> SendAsync(HttpClient client, HttpRequestMessage request, CancellationToken token)
        {
            HitResult r = new HitResult();
            r.DispatchTicks = Stopwatch.GetTimestamp();
            try
            {
                // ResponseContentRead: the task completes only after the whole body has been buffered, so "complete
                // body available" cannot be reported before the transfer ended (no truncated body can be called ready)
                HttpResponseMessage resp = await client.SendAsync(request, HttpCompletionOption.ResponseContentRead, token).ConfigureAwait(false);
                r.StatusCode = (int)resp.StatusCode;
                r.Headers = RenderHeaders(resp);
                byte[] bytes = await resp.Content.ReadAsByteArrayAsync().ConfigureAwait(false);
                r.BodyReadyTicks = Stopwatch.GetTimestamp();
                r.Body = bytes;
                r.BodyState = "complete";
                resp.Dispose();
                r.CompletedTicks = Stopwatch.GetTimestamp();
                return r;
            }
            catch (Exception ex)
            {
                Exception inner = ex;
                while (inner.InnerException != null) inner = inner.InnerException;
                if (ex is OperationCanceledException || ex is TaskCanceledException ||
                    inner is OperationCanceledException || inner is TaskCanceledException)
                {
                    r.TimedOut = true;
                    r.Error = "cancelled: " + inner.Message;
                }
                else
                {
                    r.Error = inner.Message;
                }
                r.BodyState = "unavailable";
                r.CompletedTicks = Stopwatch.GetTimestamp();
                return r;
            }
        }
    }
}
