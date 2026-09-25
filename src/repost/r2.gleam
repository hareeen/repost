import gleam/http
import gleam/int

pub type Endpoint {
  R2Endpoint(account_id: String)
  Custom(scheme: http.Scheme, host: String, port: Int)
}

@internal
pub fn endpoint_parts(endpoint: Endpoint) -> #(http.Scheme, String, Int) {
  case endpoint {
    R2Endpoint(account_id:) -> #(
      http.Https,
      account_id <> ".r2.cloudflarestorage.com",
      443,
    )
    Custom(scheme:, host:, port:) -> #(scheme, host, port)
  }
}

@internal
pub fn host_header_for(host: String, port: Int, scheme: http.Scheme) -> String {
  case scheme, port {
    http.Https, 443 -> host
    http.Http, 80 -> host
    _, _ -> host <> ":" <> int.to_string(port)
  }
}
