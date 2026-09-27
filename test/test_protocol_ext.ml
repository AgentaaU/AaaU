(* Coverage-oriented tests for the client/server wire protocol. *)

open AaaU

let fail fmt = Printf.ksprintf failwith fmt
let expect condition message = if not condition then failwith message

let test_client_round_trip () =
  let cases =
    [
      (Protocol.Input "plain text", "plain text");
      (Protocol.Resize { rows = 24; cols = 80 }, "\x01RESIZE:24,80");
      (Protocol.Ping, "\x01PING");
      (Protocol.GetStatus, "\x01GET_STATUS");
      (Protocol.ForceKill, "\x01FORCE_KILL");
      (Protocol.Unknown "\x01custom", "\x01custom");
    ]
  in
  List.iter
    (fun (message, expected) ->
      let encoded = Protocol.encode_client message in
      expect (encoded = expected)
        (Printf.sprintf "encode_client mismatch: %S <> %S" encoded expected))
    cases;
  let decoded =
    [
      ("plain text", Protocol.Input "plain text");
      ("", Protocol.Input "");
      ("\x01RESIZE:1,2", Protocol.Resize { rows = 1; cols = 2 });
      ("\x01RESIZE:1", Protocol.Unknown "\x01RESIZE:1");
      ("\x01RESIZE:a,b", Protocol.Unknown "\x01RESIZE:a,b");
      ("\x01PING", Protocol.Ping);
      ("\x01GET_STATUS", Protocol.GetStatus);
      ("\x01FORCE_KILL", Protocol.ForceKill);
      ("\x01SOMETHING:else", Protocol.Unknown "\x01SOMETHING:else");
    ]
  in
  List.iter
    (fun (input, expected) ->
      let actual = Protocol.decode_client input in
      expect (actual = expected)
        (Printf.sprintf "decode_client mismatch for %S" input))
    decoded

let test_server_round_trip () =
  let status = `Assoc [ ("ok", `Bool true) ] in
  let cases =
    [
      (Protocol.Output "bytes", "bytes");
      (Protocol.Pong, "\x01PONG");
      (Protocol.Status status, "\x01STATUS:" ^ Yojson.Safe.to_string status);
      (Protocol.Error "boom", "\x01ERROR:boom");
      (Protocol.Control "frame", "\x01CONTROL:frame");
    ]
  in
  List.iter
    (fun (message, expected) ->
      let encoded = Protocol.encode_server message in
      expect (encoded = expected)
        (Printf.sprintf "encode_server mismatch: %S <> %S" encoded expected))
    cases;
  (match Protocol.decode_server "\x01PONG" with
  | Protocol.Pong -> ()
  | _ -> fail "PONG did not decode");
  (match Protocol.decode_server ("\x01STATUS:" ^ Yojson.Safe.to_string status) with
  | Protocol.Status decoded when decoded = status -> ()
  | _ -> fail "STATUS did not decode");
  (match Protocol.decode_server "\x01STATUS:not-json" with
  | Protocol.Control "STATUS:not-json" -> ()
  | _ -> fail "invalid STATUS was not downgraded to Control");
  (match Protocol.decode_server "\x01ERROR:oops" with
  | Protocol.Error "oops" -> ()
  | _ -> fail "ERROR did not decode");
  (match Protocol.decode_server "\x01CONTROL:hello" with
  | Protocol.Control "hello" -> ()
  | _ -> fail "CONTROL did not decode");
  (match Protocol.decode_server "\x01WEIRD" with
  | Protocol.Control "WEIRD" -> ()
  | _ -> fail "unknown server control was not preserved");
  (match Protocol.decode_server "plain" with
  | Protocol.Output "plain" -> ()
  | _ -> fail "plain output did not decode");
  (match Protocol.decode_server "" with
  | Protocol.Output "" -> ()
  | _ -> fail "empty output did not decode")

let test_is_control () =
  expect (Protocol.is_control "\x01PING") "control byte not detected";
  expect (not (Protocol.is_control "PING")) "plain text treated as control";
  expect (not (Protocol.is_control "")) "empty string treated as control"

let test_framing () =
  let round_trip payload =
    match Protocol.try_parse_framed (Protocol.frame_message payload ^ "tail") with
    | Some (message, remaining) when message = payload && remaining = "tail" -> ()
    | _ -> fail "valid frame did not round trip"
  in
  round_trip "";
  round_trip "hello";
  round_trip (String.make 1000 'x');

  (* Incomplete header or body. *)
  (match Protocol.try_parse_framed "abc" with
  | None -> ()
  | Some _ -> fail "short buffer parsed as a frame");
  (match Protocol.try_parse_framed (Protocol.frame_message "payload" |> fun s -> String.sub s 0 (String.length s - 2)) with
  | None -> ()
  | Some _ -> fail "truncated frame parsed as complete");

  (* Oversized and negative lengths are rejected. *)
  let oversized = Bytes.make 4 '\000' in
  Bytes.set_int32_be oversized 0 (Int32.of_int (Protocol.max_frame_size + 1));
  (match Protocol.try_parse_framed (Bytes.unsafe_to_string oversized) with
  | None -> ()
  | Some _ -> fail "oversized frame accepted");
  let negative = Bytes.make 4 '\255' in
  (match Protocol.try_parse_framed (Bytes.unsafe_to_string negative) with
  | None -> ()
  | Some _ -> fail "negative frame length accepted")

let () =
  test_client_round_trip ();
  test_server_round_trip ();
  test_is_control ();
  test_framing ();
  print_endline "protocol tests passed"
