///|
/// Monitor web server, built on the moonback framework (routing, response
/// helpers, connection handling) instead of hand-rolled HTTP plumbing.

///|
/// Serve the monitor UI and JSON API on `host:port`.
pub async fn run_web_server(
  host : String,
  port : Int32,
  store : FlowStore,
) -> Unit {
  let app = @moonback.App(
    @moonback.Module(ctx => {
      ctx.get("/", (_req, res) => {
        res.send_text(index_html, headers=[
          ("Content-Type", "text/html; charset=utf-8"),
        ])
      })
      ctx.get("/frontend.js", (_req, res) => {
        res.send_text(frontend_js, headers=[
          ("Content-Type", "text/javascript; charset=utf-8"),
        ])
      })
      ctx.get("/api/flows", (_req, res) => {
        res.send_json(store.list_response().to_json())
      })
      ctx.get("/api/flows/:id", (req, res) => {
        let id = match req.params.get("id") {
          Some(s) =>
            @string.parse_int(s) catch {
              _ => {
                res.send_text("invalid flow id", status=404)
                return
              }
            }
          None => {
            res.send_text("invalid flow id", status=404)
            return
          }
        }
        match store.detail(id) {
          Some(detail) => res.send_json(detail.to_json())
          None => res.send_text("flow not found", status=404)
        }
      })
      ctx.add_route(@http.RequestMethod::Delete, "/api/flows", (_req, res) => {
        store.clear()
        res.send_json(@json.Json::object({ "ok": @json.Json::boolean(true) }))
      })
      ctx.add_route(@http.RequestMethod::Put, "/api/intercept", (req, res) => {
        let body = req.body.json() catch {
          _ => {
            res.send_text("invalid JSON body", status=400)
            return
          }
        }
        let state : @shared.InterceptState = @json.from_json(body) catch {
          _ => {
            res.send_text("expected {\"enabled\":bool}", status=400)
            return
          }
        }
        store.set_intercept_enabled(state.enabled)
        println(
          "[monitor] intercept switched " +
          (if state.enabled { "on" } else { "off" }),
        )
        let now : @shared.InterceptState = {
          enabled: store.intercept_enabled(),
        }
        res.send_json(now.to_json())
      })
    }),
  )
  defer app.close()
  let server = @moonback.listen(host~, port=port.to_uint16(), reuse_addr=true)
  app.serve(server)
}
