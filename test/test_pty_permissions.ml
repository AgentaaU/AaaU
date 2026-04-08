(** Verify PTY creation does not expose the slave device to all users. *)

let test_open_pty_permissions () =
  match AaaU.Pty.open_pty () with
  | Error err ->
    Printf.printf "FAIL: failed to open PTY: %s\n%!" err;
    false
  | Ok (pty, _slave) ->
    let slave_path = AaaU.Pty.get_slave_path pty in
    let result =
      try
        let stat = Unix.stat (slave_path :> string) in
        let world_writable = stat.Unix.st_perm land 0o002 <> 0 in
        if world_writable then begin
          Printf.printf "FAIL: PTY slave is world-writable: %s (%03o)\n%!" (slave_path :> string) stat.Unix.st_perm;
          false
        end else begin
          Printf.printf "PASS: PTY slave is not world-writable: %s (%03o)\n%!" (slave_path :> string) stat.Unix.st_perm;
          true
        end
      with exn ->
        Printf.printf "FAIL: stat on PTY slave failed: %s\n%!" (Printexc.to_string exn);
        false
    in
    ignore (Lwt_main.run (AaaU.Pty.close pty));
    result

let () =
  Printf.printf "=== Test: PTY permissions ===\n%!";
  let result = test_open_pty_permissions () in
  if result then
    Printf.printf "PASS\n%!"
  else begin
    Printf.printf "FAIL\n%!";
    exit 1
  end
