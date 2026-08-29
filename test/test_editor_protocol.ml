let fail message = prerr_endline message; exit 1
let expect condition message = if not condition then fail message

let () =
  let binary = "a\000b\255c" in
  let request = { AaaU.Editor_protocol.request_id = "r1"; content = binary } in
  let encoded = AaaU.Editor_protocol.request_to_string request in
  begin match AaaU.Editor_protocol.request_of_string encoded with
  | Ok decoded -> expect (decoded.content = binary) "binary request did not round trip"
  | Error message -> fail message
  end;
  let response = { AaaU.Editor_protocol.request_id = "r1"; status = 0; error = None; content = Some binary } in
  begin match AaaU.Editor_protocol.response_of_string (AaaU.Editor_protocol.response_to_string response) with
  | Ok decoded -> expect (decoded.content = Some binary) "binary response did not round trip"
  | Error message -> fail message
  end;
  let oversized = String.make (AaaU.Editor_protocol.max_payload + 1) 'x' in
  expect (Result.is_error (AaaU.Editor_protocol.frame oversized)) "oversized frame accepted";
  print_endline "editor protocol tests passed"
