///|
/// Shared API contract between the proxy backend and the monitor frontend.
/// Both sides derive JSON codecs from these types, so the wire format is
/// defined exactly once (see the fullstack tutorial: shared/ package).

///|
pub extend FlowSummary with ToJson::{to_json}

///|
pub extend FlowSummary with @json.FromJson::{from_json}

///|
pub extend FlowsResponse with ToJson::{to_json}

///|
pub extend FlowsResponse with @json.FromJson::{from_json}

///|
pub extend RequestData with ToJson::{to_json}

///|
pub extend RequestData with @json.FromJson::{from_json}

///|
pub extend UpstreamRequest with ToJson::{to_json}

///|
pub extend UpstreamRequest with @json.FromJson::{from_json}

///|
pub extend ResponseData with ToJson::{to_json}

///|
pub extend ResponseData with @json.FromJson::{from_json}

///|
pub extend FlowDetail with ToJson::{to_json}

///|
pub extend FlowDetail with @json.FromJson::{from_json}

///|
pub extend InterceptState with ToJson::{to_json}

///|
pub extend InterceptState with @json.FromJson::{from_json}

///|
/// One row of the flow list (`GET /api/flows`).
#derive(Eq, Debug, ToJson, FromJson)
pub(all) struct FlowSummary {
  id : Int32
  start_ms : Double
  http_method : String
  path : String
  status : Int32
  reason : String
  intercepted : Bool
  injected : Bool
  pending : Bool
  error : String?
  req_size : Int32
  resp_size : Int32
  duration_ms : Int32
  content_type : String
}

///|
/// Payload of `GET /api/flows`.
#derive(Eq, Debug, ToJson, FromJson)
pub(all) struct FlowsResponse {
  total : Int32
  injected_total : Int32
  stored : Int32
  capacity : Int32
  /// Live interception switch (runtime-toggleable from the monitor UI).
  intercept_enabled : Bool
  flows : Array[FlowSummary]
}

///|
/// Body / response of `PUT /api/intercept`: the runtime interception switch.
#derive(Eq, Debug, ToJson, FromJson)
pub(all) struct InterceptState {
  enabled : Bool
}

///|
/// Request side of a flow detail.
#derive(Eq, Debug, ToJson, FromJson)
pub(all) struct RequestData {
  http_method : String
  target : String
  headers : Array[(String, String)]
  body : String
  truncated : Bool
  size : Int32
}

///|
/// The rewritten body actually forwarded upstream (only present when the
/// system prefix was injected).
#derive(Eq, Debug, ToJson, FromJson)
pub(all) struct UpstreamRequest {
  body : String
  truncated : Bool
}

///|
/// Response side of a flow detail.
#derive(Eq, Debug, ToJson, FromJson)
pub(all) struct ResponseData {
  status : Int32
  reason : String
  headers : Array[(String, String)]
  body : String
  truncated : Bool
  size : Int32
}

///|
/// Payload of `GET /api/flows/<id>`.
#derive(Eq, Debug, ToJson, FromJson)
pub(all) struct FlowDetail {
  id : Int32
  start_ms : Double
  duration_ms : Int32
  client_addr : String
  upstream : String
  intercepted : Bool
  injected : Bool
  pending : Bool
  error : String?
  request : RequestData
  upstream_request : UpstreamRequest?
  response : ResponseData?
}
