import json
import sys
import threading
from concurrent.futures import ThreadPoolExecutor

from .diagnostics import environment_summary, log_diagnostic
from .protocol import ProtocolError, error_response, parse_request, response
from .service import EngineService


def main() -> int:
    service = EngineService()
    output_lock = threading.Lock()
    # Preview extraction can spend 20 seconds in FFmpeg. Keep it off the
    # interactive command loop; mutations still run serially in request order.
    previews = ThreadPoolExecutor(max_workers=1, thread_name_prefix="preview")
    threading.Thread(
        target=lambda: log_diagnostic(environment_summary()),
        name="environment-log",
        daemon=True,
    ).start()

    def write_output(output):
        line = json.dumps(output, ensure_ascii=False, separators=(",", ":")) + "\n"
        with output_lock:
            sys.stdout.write(line)
            sys.stdout.flush()

    def handle_request(request):
        request_id = request.get("request_id")
        try:
            result = service.handle(request["command"], request.get("payload", {}))
            output = response(request_id, result)
        except ProtocolError as exc:
            output = error_response(request_id, exc.code, exc.message, exc.details)
        except Exception as exc:
            output = error_response(request_id, "ENGINE_ERROR", str(exc))
        write_output(output)

    try:
        for raw_line in sys.stdin:
            line = raw_line.strip()
            if not line:
                continue
            request_id = None
            try:
                request = parse_request(line)
                request_id = request.get("request_id")
                if request["command"] == "extract_preview":
                    previews.submit(handle_request, request)
                else:
                    handle_request(request)
            except ProtocolError as exc:
                write_output(error_response(request_id, exc.code, exc.message, exc.details))
            except Exception as exc:
                write_output(error_response(request_id, "ENGINE_ERROR", str(exc)))
    finally:
        previews.shutdown(wait=True)
        service.shutdown()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
