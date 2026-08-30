open AaaU

let fail fmt = Printf.ksprintf failwith fmt

let test_round_trip () =
  let payload = "hello\000world" in
  match Protocol.try_parse_framed (Protocol.frame_message payload ^ "rest") with
  | Some (message, remaining) when message = payload && remaining = "rest" -> ()
  | _ -> fail "failed to parse a valid framed message"

let test_rejects_oversized_payload () =
  let frame = Bytes.make 4 '\000' in
  Bytes.set_int32_be frame 0 (Int32.of_int (Protocol.max_frame_size + 1));
  match Protocol.try_parse_framed (Bytes.unsafe_to_string frame) with
  | None -> ()
  | Some _ -> fail "accepted a frame larger than the configured limit"

let test_control_payloads_preserve_colons () =
  let encoded = Protocol.encode_server (Protocol.Error "network: connection lost") in
  match Protocol.decode_server encoded with
  | Protocol.Error "network: connection lost" -> ()
  | _ -> fail "control payload containing a colon was not preserved"

let () =
  test_round_trip ();
  test_rejects_oversized_payload ();
  test_control_payloads_preserve_colons ();
  print_endline "protocol framing tests passed"
