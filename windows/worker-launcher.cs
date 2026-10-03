// Compile as a WindowsApplication: a scheduled task must never own a terminal.
// The child also uses CREATE_NO_WINDOW, rather than merely hiding its window.
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text;

internal static class EnanaWorkerLauncher {
    private static string home;
    private static void Log(string eventName, int code) {
        try {
            string file = Path.Combine(home, "launcher.log");
            if (File.Exists(file) && new FileInfo(file).Length > 1048576) {
                string previous = file + ".previous";
                if (File.Exists(previous)) File.Delete(previous);
                File.Move(file, previous);
            }
            // Only fixed event names and numeric codes. No arguments, URLs or
            // exception text that might contain account/node credentials.
            File.AppendAllText(file, "{\"at\":\"" + DateTime.UtcNow.ToString("o") +
                "\",\"event\":\"" + eventName + "\",\"code\":" +
                code.ToString(CultureInfo.InvariantCulture) + "}\n", new UTF8Encoding(false));
        } catch { } // Logging must not hide the original exit code.
    }
    private static int Main() {
        home = Directory.GetParent(AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar)).FullName;
        try {
            var start = new ProcessStartInfo {
                FileName = Path.Combine(home, "runtime", "node", "node.exe"),
                Arguments = "\"" + Path.Combine(home, "windows", "worker.js") + "\" \"" + home + "\"",
                WorkingDirectory = home,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardInput = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };
            using (var child = new Process { StartInfo = start }) {
                // Drain both streams without retaining unredacted output. The
                // worker records detailed, redacted failures in worker.log.
                child.OutputDataReceived += delegate { };
                child.ErrorDataReceived += delegate { };
                child.Start();
                child.StandardInput.Close();
                child.BeginOutputReadLine();
                child.BeginErrorReadLine();
                Log("launcher.started", child.Id);
                // Stay alive for the worker lifetime so Task Scheduler's
                // Running state, exit status and restart policy remain valid.
                child.WaitForExit();
                Log("launcher.exited", child.ExitCode);
                return child.ExitCode;
            }
        } catch (Win32Exception error) {
            Log("launcher.failed", error.NativeErrorCode);
            return 1;
        } catch {
            Log("launcher.failed", 1);
            return 1;
        }
    }
}
