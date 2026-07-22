There is an Apache-style access log at /app/access.log. Every non-blank line is one
HTTP request and looks like this:

    192.168.0.1 - - [16/Jun/2026:10:00:01 +0000] "GET /index.html HTTP/1.1" 200 1024

The first whitespace-separated field is the client IP address, and the quoted request
section holds the HTTP method followed by the requested path.

Parse the log and write a summary report to /app/report.json as a single JSON object
with exactly these keys:

- "total_requests": the total number of non-blank log lines.
- "unique_ips": the number of distinct client IP addresses (the first field of each line).
- "top_path": the request path (e.g. "/index.html") that appears most often across all
  requests.

Success criteria:

1. /app/report.json exists and holds a JSON object with exactly the three keys
   "total_requests", "unique_ips", and "top_path", with no additional keys.
2. "total_requests" equals the number of non-blank lines in /app/access.log.
3. "unique_ips" equals the number of distinct client IP addresses in /app/access.log.
4. "top_path" equals the most-requested path in /app/access.log.
