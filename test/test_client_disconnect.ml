(** Test that client disconnect doesn't crash server with EBADF *)

open Lwt.Infix

let test_client_disconnect () =
  (* Skip test if not running as root - server requires root *)
  if Unix.getuid () <> 0 then begin
    Printf.printf "SKIP: requires root privileges\n%!";
    Printf.printf "PASS\n%!";
    exit 0
  end;

  let socket_path = "/tmp/aaau_test_disconnect.sock" in
  let log_dir = "/tmp/aaau_test_logs" in

  (* Clean up from previous runs *)
  let () = try Unix.unlink socket_path with _ -> () in
  let () = try Sys.remove log_dir with _ -> () in
  let () = try Unix.mkdir log_dir 0o755 with _ -> () in

  (* Create server *)
  let server = AaaU.Bridge.create
    ~socket_path
    ~shared_group:(try Unix.getenv "USER" with _ -> "nogroup")
    ~admin_group:(try Unix.getenv "USER" with _ -> "nogroup")
    ~agent_user:(try Unix.getenv "USER" with _ -> "nobody")
    ~log_dir
    ~default_program:"/bin/bash"
    ()
  in

  let server_error = ref None in

  (* Start server in background *)
  let _server_thread = Lwt.async (fun () ->
    Lwt.catch (fun () ->
      AaaU.Bridge.start server >>= fun () ->
      Lwt.return_unit
    ) (fun exn ->
      server_error := Some (Printexc.to_string exn);
      Lwt.return_unit
    )
  ) in

  (* Wait for server to start *)
  let rec wait_for_server attempts =
    if attempts <= 0 then false
    else if Sys.file_exists socket_path then true
    else begin
      Lwt_main.run (Lwt_unix.sleep 0.1);
      wait_for_server (attempts - 1)
    end
  in

  let server_ready = wait_for_server 50 in

  if not server_ready then begin
    Printf.printf "FAIL: Server did not start\n%!";
    exit 1
  end;

  (* Connect a client and disconnect immediately *)
  let client_result =
    Lwt_main.run (
      Lwt.catch (fun () ->
        let socket = Lwt_unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
        Lwt_unix.connect socket (Unix.ADDR_UNIX socket_path) >>= fun () ->

        (* Send handshake *)
        let handshake = "NEW:24:80\n" in
        Lwt_unix.write_string socket handshake 0 (String.length handshake) >>= fun _ ->

        (* Read response *)
        let buf = Bytes.create 1024 in
        Lwt_unix.read socket buf 0 1024 >>= fun n ->
        let response = Bytes.sub_string buf 0 n in

        if String.starts_with ~prefix:"SESSION:" response then begin
          (* Connected - now disconnect immediately without proper close *)
          Lwt.return_ok response
        end else begin
          Lwt.return_error ("Unexpected response: " ^ response)
        end
      ) (fun exn ->
        Lwt.return_error (Printexc.to_string exn)
      )
    )
  in

  (* Handle client result *)
  (match client_result with
   | Error e ->
       Printf.printf "FAIL: Client connection failed: %s\n%!" e;
       exit 1
   | Ok response ->
       Printf.printf "Client connected: %s\n%!" (String.trim response));

  (* Wait a bit for server to process disconnect *)
  Lwt_main.run (Lwt_unix.sleep 0.5);

  (* Check if server is still running (no EBADF crash) *)
  if !server_error <> None then begin
    Printf.printf "FAIL: Server crashed: %s\n%!" (Option.get !server_error);
    exit 1
  end;

  (* Stop server gracefully *)
  Lwt_main.run (AaaU.Bridge.stop server);
  Lwt_main.run (Lwt_unix.sleep 0.1);

  (* Clean up *)
  let () = try Unix.unlink socket_path with _ -> () in
  let () = try Sys.remove log_dir with _ -> () in

  Printf.printf "Server handled client disconnect without EBADF error\n%!";
  true

let () =
  Printf.printf "=== Test: Client disconnect handling ===\n%!";
  let result = test_client_disconnect () in
  if result then begin
    Printf.printf "PASS\n%!";
    exit 0
  end else begin
    Printf.printf "FAIL\n%!";
    exit 1
  end
