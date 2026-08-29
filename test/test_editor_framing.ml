open Lwt.Syntax

let fail message = prerr_endline message; exit 1

let () =
  Lwt_main.run begin
    let left, right = Lwt_unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
    let payload = String.make 10000 'p' in
    let framed = match AaaU.Editor_protocol.frame payload with Ok value -> value | Error message -> fail message in
    let writer =
      let rec loop offset =
        if offset = String.length framed then Lwt.return_unit
        else
          let count = min 3 (String.length framed - offset) in
          let* written = Lwt_unix.write_string left framed offset count in
          loop (offset + written)
      in loop 0
    in
    let reader = AaaU.Editor_protocol.read_frame right in
    let* (), result = Lwt.both writer reader in
    begin match result with Ok value when value = payload -> () | _ -> fail "partial frame read failed" end;
    let header = Bytes.of_string "\255\255\255\255" in
    let* _ = Lwt_unix.write left header 0 4 in
    let* result = AaaU.Editor_protocol.read_frame right in
    begin match result with Error _ -> () | Ok _ -> fail "oversized header accepted" end;
    let stalled_left, stalled_right = Lwt_unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
    let* stalled = AaaU.Editor_protocol.read_frame ~timeout:0.01 stalled_right in
    begin match stalled with Error "Editor frame timed out" -> () | _ -> fail "stalled editor frame did not time out" end;
    let* () = Lwt_unix.close stalled_left in
    let* () = Lwt_unix.close stalled_right in
    let* () = Lwt_unix.close left in Lwt_unix.close right
  end;
  print_endline "editor framing tests passed"
