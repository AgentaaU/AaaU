(* Coverage-oriented tests for the bounded editor protocol. *)

open Lwt.Syntax

let fail fmt = Printf.ksprintf failwith fmt
let expect condition message = if not condition then failwith message

let expect_error label result =
  match result with
  | Ok _ -> fail "%s unexpectedly succeeded" label
  | Error _ -> ()

let test_request_parsing () =
  let request = { AaaU.Editor_protocol.request_id = "id"; content = "binary\000data" } in
  (match AaaU.Editor_protocol.request_of_string (AaaU.Editor_protocol.request_to_string request) with
  | Ok decoded ->
    expect (decoded.request_id = "id") "request id mismatch";
    expect (decoded.content = request.content) "request content mismatch"
  | Error message -> fail "request round trip failed: %s" message);
  expect_error "array request" (AaaU.Editor_protocol.request_of_string "[]");
  expect_error "missing id" (AaaU.Editor_protocol.request_of_string "{\"content_hex\":\"00\"}");
  expect_error "empty id" (AaaU.Editor_protocol.request_of_string "{\"request_id\":\"\",\"content_hex\":\"00\"}");
  expect_error "missing content" (AaaU.Editor_protocol.request_of_string "{\"request_id\":\"id\"}");
  expect_error "odd hex" (AaaU.Editor_protocol.request_of_string "{\"request_id\":\"id\",\"content_hex\":\"0\"}");
  expect_error "bad hex" (AaaU.Editor_protocol.request_of_string "{\"request_id\":\"id\",\"content_hex\":\"zz\"}");
  expect_error "malformed json" (AaaU.Editor_protocol.request_of_string "not-json");
  let oversized = String.make ((AaaU.Editor_protocol.max_buffer_size * 2) + 2) 'a' in
  expect_error "oversized content"
    (AaaU.Editor_protocol.request_of_string
       (Printf.sprintf "{\"request_id\":\"id\",\"content_hex\":\"%s\"}" oversized))

let test_response_parsing () =
  let response =
    {
      AaaU.Editor_protocol.request_id = "id";
      status = 7;
      error = Some "failure";
      content = Some "data";
    }
  in
  (match AaaU.Editor_protocol.response_of_string (AaaU.Editor_protocol.response_to_string response) with
  | Ok decoded ->
    expect (decoded.request_id = "id") "response id mismatch";
    expect (decoded.status = 7) "response status mismatch";
    expect (decoded.error = Some "failure") "response error mismatch";
    expect (decoded.content = Some "data") "response content mismatch"
  | Error message -> fail "response round trip failed: %s" message);
  let minimal =
    { AaaU.Editor_protocol.request_id = "id"; status = 0; error = None; content = None }
  in
  (match AaaU.Editor_protocol.response_of_string (AaaU.Editor_protocol.response_to_string minimal) with
  | Ok decoded -> expect (decoded.error = None && decoded.content = None) "minimal response mismatch"
  | Error message -> fail "minimal response failed: %s" message);
  expect_error "array response" (AaaU.Editor_protocol.response_of_string "[]");
  expect_error "missing id" (AaaU.Editor_protocol.response_of_string "{\"status\":0}");
  expect_error "empty id" (AaaU.Editor_protocol.response_of_string "{\"request_id\":\"\",\"status\":0}");
  expect_error "missing status" (AaaU.Editor_protocol.response_of_string "{\"request_id\":\"id\"}");
  expect_error "negative status" (AaaU.Editor_protocol.response_of_string "{\"request_id\":\"id\",\"status\":-1}");
  expect_error "large status" (AaaU.Editor_protocol.response_of_string "{\"request_id\":\"id\",\"status\":256}");
  expect_error "non-integer status" (AaaU.Editor_protocol.response_of_string "{\"request_id\":\"id\",\"status\":\"x\"}");
  expect_error "long error"
    (AaaU.Editor_protocol.response_of_string
       (Printf.sprintf "{\"request_id\":\"id\",\"status\":1,\"error\":\"%s\"}"
          (String.make 5000 'e')));
  expect_error "bad content" (AaaU.Editor_protocol.response_of_string "{\"request_id\":\"id\",\"status\":1,\"content_hex\":\"zz\"}");
  expect_error "malformed json" (AaaU.Editor_protocol.response_of_string "not-json")

let test_framing () =
  expect_error "oversized frame" (AaaU.Editor_protocol.frame (String.make (AaaU.Editor_protocol.max_payload + 1) 'x'));
  Lwt_main.run
    (let left, right = Lwt_unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
     let* written = AaaU.Editor_protocol.write_frame left "payload" in
     (match written with Ok () -> () | Error message -> fail "write_frame failed: %s" message);
     let* read = AaaU.Editor_protocol.read_frame right in
     (match read with Ok value -> expect (value = "payload") "frame payload mismatch" | Error message -> fail "read_frame failed: %s" message);
     let* () = Lwt_unix.close left in
     let* closed = AaaU.Editor_protocol.read_frame right in
     (match closed with Error _ -> () | Ok _ -> fail "read_frame accepted a closed connection");
     let* () = Lwt_unix.close right in
     (* Oversized header is rejected. *)
     let a, b = Lwt_unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
     let header = Bytes.make 4 '\255' in
     let* _ = Lwt_unix.write a header 0 4 in
     let* result = AaaU.Editor_protocol.read_frame b in
     (match result with Error _ -> () | Ok _ -> fail "oversized frame header accepted");
     let* () = Lwt_unix.close a in
     Lwt_unix.close b)

let () =
  test_request_parsing ();
  test_response_parsing ();
  test_framing ();
  print_endline "editor protocol extended tests passed"
