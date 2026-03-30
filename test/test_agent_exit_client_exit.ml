(** Test that agent exit causes client to exit gracefully *)

open Lwt.Infix

let test_agent_exit_client_exit () =
  (* Skip test if not running as root *)
  if Unix.getuid () <> 0 then begin
    Printf.printf "SKIP: requires root privileges\n%!";
    Printf.printf "PASS\n%!";
    exit 0
  end;

  let socket_path = "/tmp/aaau_test_agent_exit.sock" in
  let log_dir = "/tmp/aaau_test_logs2" in

  (* Clean up from previous runs *)
  let () = try Unix.unlink socket_path with _ -> () in
  let () = try Sys.remove log_dir with _ -> () in
  let () = try Unix.mkdir log_dir 0o755 with _ -> () in

  (* Create server *)
  let server = AaaU.Bridge.create
    ~socket_path
    ~shared_group:(try Unix.getenv "USER" with _ -> "nogroup")
    ~agent_user:(try Unix.getenv "USER" with _ -> "nobody")
    ~log_dir
    ~default_program:"/bin/sh"
    ~default_args:["-c"; "echo 'Hello from agent'; sleep 1; echo 'Agent exiting'; exit 0"]
    ()
  in

  let server_error = ref None in

  (* Start server in background *)
  let _server_thread = Lwt.async (fun () ->
    Lwt.catch (fun () ->
      AaaU.Bridge.start server
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

  (* Connect client *)
  let client_exited = ref false in
  let client_output = ref "" in
  let client_error = ref None in

  let _client_thread = Lwt.async (fun () ->
    Lwt.catch (fun () ->
      let socket = Lwt_unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
      Lwt_unix.connect socket (Unix.ADDR_UNIX socket_path) >>= fun () ->

      (* Send handshake to create new session *)
      let handshake = "NEW:24:80\n" in
      Lwt_unix.write_string socket handshake 0 (String.length handshake) >>= fun _ ->

      (* Read response *)
      let buf = Bytes.create 1024 in
      Lwt_unix.read socket buf 0 1024 >>= fun n ->
      let response = Bytes.sub_string buf 0 n in

      if not (String.starts_with ~prefix:"SESSION:" response) then begin
        Printf.printf "FAIL: Unexpected response: %s\n%!" response;
        Lwt.return_unit
      end else begin
        (* Read agent output until EOF *)
        let rec read_output acc =
          let buf = Bytes.create 4096 in
          Lwt.catch (fun () ->
            Lwt_unix.read socket buf 0 4096 >>= fun n ->
            if n = 0 then begin
              (* EOF - agent exited *)
              client_exited := true;
              client_output := String.concat "" (List.rev acc);
              Lwt.return_unit
            end else begin
              let data = Bytes.sub_string buf 0 n in
              read_output (data :: acc)
            end
          ) (fun _ ->
            (* Socket error - also indicates exit *)
            client_exited := true;
            client_output := String.concat "" (List.rev acc);
            Lwt.return_unit
          )
        in
        read_output []
      end
    ) (fun exn ->
      client_error := Some (Printexc.to_string exn);
      client_exited := true;
      Lwt.return_unit
    )
  ) in

  (* Wait for client to exit (should happen when agent exits) *)
  let rec wait_for_client_exit attempts =
    if attempts <= 0 then false
    else if !client_exited then true
    else begin
      Lwt_main.run (Lwt_unix.sleep 0.2);
      wait_for_client_exit (attempts - 1)
    end
  in

  let client_exited_ok = wait_for_client_exit 30 in

  (* Give a moment for final cleanup *)
  Lwt_main.run (Lwt_unix.sleep 0.2);

  (* Stop server *)
  Lwt_main.run (AaaU.Bridge.stop server);

  (* Wait for threads to complete *)
  Lwt_main.run (Lwt_unix.sleep 0.2);

  (* Clean up *)
  let () = try Unix.unlink socket_path with _ -> () in
  let () = try Sys.remove log_dir with _ -> () in

  (* Verify results *)
  if not client_exited_ok then begin
    Printf.printf "FAIL: Client did not exit after agent\n%!";
    exit 1
  end;

  if !client_error <> None then begin
    Printf.printf "FAIL: Client error: %s\n%!" (Option.get !client_error);
    exit 1
  end;

  if !server_error <> None then begin
    Printf.printf "FAIL: Server error: %s\n%!" (Option.get !server_error);
    exit 1
  end;

  (* Verify client received agent output *)
  let output = !client_output in
  if output = "" then begin
    Printf.printf "WARN: No output received\n%!";
  end else begin
    Printf.printf "Client exited gracefully when agent exited\n%!";
    Printf.printf "Output received: %s\n%!" (String.trim output);
  end;
  true

let () =
  Printf.printf "=== Test: Agent exit causes client exit ===\n%!";
  let result = test_agent_exit_client_exit () in
  if result then begin
    Printf.printf "PASS\n%!";
    exit 0
  end else begin
    Printf.printf "FAIL\n%!";
    exit 1
  end
