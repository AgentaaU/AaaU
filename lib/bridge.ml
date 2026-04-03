(** Server implementation *)

open Lwt.Syntax

type t = {
  socket_path : string;
  shared_group : string;
  agent_user : string;
  default_program : string;
  default_args : string list;

  mutable server_socket : Lwt_unix.file_descr option;
  audit : Audit.t;
  sessions : (string, Session.t) Hashtbl.t;
  sessions_lock : Lwt_mutex.t;
  mutable running : bool;
}

let create ~socket_path ~shared_group ~agent_user ~log_dir ?(default_program="/bin/bash") ?(default_args=["-l"]) () =
  let audit = Audit.create ~log_dir in
  {
    socket_path;
    shared_group;
    agent_user;
    default_program;
    default_args;
    server_socket = None;
    audit;
    sessions = Hashtbl.create 100;
    sessions_lock = Lwt_mutex.create ();
    running = false;
  }

let setup_socket t =
  (* Clean up old socket *)
  (try Unix.unlink t.socket_path with _ -> ());

  (* Create directory *)
  let dir = Filename.dirname t.socket_path in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error _ -> ());

  (* Create socket *)
  let socket = Lwt_unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  let* () = Lwt_unix.bind socket (Unix.ADDR_UNIX t.socket_path) in
  Lwt_unix.listen socket 5;
  let* () = Lwt.return_unit in

  (* Set permissions *)
  let gid = (Unix.getgrnam t.shared_group).Unix.gr_gid in
  Unix.chown t.socket_path 0 gid;
  Unix.chmod t.socket_path 0o660;

  t.server_socket <- Some socket;

  Logs_lwt.info (fun m -> m "Server listening on %s" t.socket_path)

let authenticate_client t client_fd =
  Lwt.return (Auth.authenticate_socket (Lwt_unix.unix_file_descr client_fd) ~shared_group:t.shared_group)

let handle_handshake t client_fd user_info =
  (* Read handshake message *)
  let buf = Bytes.create 1024 in
  let* n = Lwt_unix.read client_fd buf 0 1024 in

  if n = 0 then
    Lwt.return_error "Connection closed"
  else
    let msg = Bytes.sub_string buf 0 n in
    let msg = String.trim msg in

    if String.starts_with ~prefix:"SESSION:" msg then
      let session_id = String.sub msg 8 (String.length msg - 8) in
      Lwt_mutex.with_lock t.sessions_lock (fun () ->
        match Hashtbl.find_opt t.sessions session_id with
        | None -> Lwt.return_error (Printf.sprintf "Session %s not found" session_id)
        | Some session ->
          let response = Printf.sprintf "SESSION:%s\n" session_id in
          let* _ = Lwt_unix.write_string client_fd response 0 (String.length response) in
          Lwt.return_ok (`Existing session)
      )
    else if String.starts_with ~prefix:"NEW" msg then
      (* Parse "NEW:rows:cols" or "NEW:program:rows:cols" or "NEW:program:arg1:arg2:...:rows:cols" *)
      (* Last two fields are always rows and cols *)
      let parts = String.split_on_char ':' msg in
      let program, args, rows, cols =
        match parts with
        | ["NEW"; rows_str; cols_str] ->
          (* NEW:rows:cols - use default program *)
          let r = int_of_string_opt rows_str |> Option.value ~default:24 in
          let c = int_of_string_opt cols_str |> Option.value ~default:80 in
          (t.default_program, t.default_args, r, c)
        | "NEW" :: prog :: rest when prog <> "" ->
          (* NEW:program:...:rows:cols - parse program, args, and size *)
          (* Last two elements should be rows and cols *)
          let len = List.length rest in
          if len >= 2 then
            let rows_str = List.nth rest (len - 2) in
            let cols_str = List.nth rest (len - 1) in
            match int_of_string_opt rows_str, int_of_string_opt cols_str with
            | Some r, Some c ->
              (* Extract args - everything between program and rows/cols *)
              let args = if len > 2 then 
                let rec take n lst = match n, lst with
                  | 0, _ | _, [] -> []
                  | n, x::xs -> x :: take (n-1) xs
                in
                take (len - 2) rest 
              else [] in
              (prog, args, r, c)
            | _ ->
              (* Not valid numbers, treat all as args with default size *)
              (prog, rest, 24, 80)
          else
            (* Not enough parts for rows/cols *)
            (prog, rest, 24, 80)
        | _ -> 
          (t.default_program, t.default_args, 24, 80)
      in
      let session_id = Uuidm.v4_gen (Random.State.make_self_init ()) () |> Uuidm.to_string in
      let* result = Session.create ~session_id ~creator:user_info.Auth.username ~agent_user:t.agent_user 
        ~program ~args ~rows ~cols ~audit:t.audit in
      match result with
      | Error e -> Lwt.return_error e
      | Ok session ->
        let* () =
          Lwt_mutex.with_lock t.sessions_lock (fun () ->
            Hashtbl.add t.sessions session_id session;
            Lwt.return_unit
          )
        in
        let response = Printf.sprintf "SESSION:%s\n" session_id in
        let* _ = Lwt_unix.write_string client_fd response 0 (String.length response) in
        Lwt.return_ok (`New session)
    else
      Lwt.return_error "Invalid handshake. Use SESSION:id or NEW"

let handle_client t client_fd addr =
  let* () = Logs_lwt.info (fun m -> m "New connection from %s" addr) in

  (* Authentication *)
  let* auth_result = authenticate_client t client_fd in
  match auth_result with
  | Error e ->
    let* _ = Lwt_unix.write_string client_fd ("Auth failed: " ^ e ^ "\n") 0
        (String.length e + 12) in
    Lwt_unix.close client_fd

  | Ok user_info ->
    (* Handshake - wrap in exception handling *)
    let* () = Lwt.try_bind
      (fun () ->
        let* handshake_result = handle_handshake t client_fd user_info in
        match handshake_result with
        | Error e ->
          let* _ = Lwt_unix.write_string client_fd (e ^ "\n") 0 (String.length e + 1) in
          Lwt_unix.close client_fd
        | Ok (`Existing _ | `New _ as handshake_result') ->
          let session =
            match handshake_result' with
            | `Existing s -> s
            | `New s -> s
            | _ -> failwith "impossible"
          in

          (* Add client *)
          let* client_result =
            Session.add_client session ~socket:client_fd ~addr ~user_info
          in
          match client_result with
          | Error e ->
            let* _ = Lwt_unix.write_string client_fd (e ^ "\n") 0 (String.length e + 1) in
            Lwt_unix.close client_fd

          | Ok client ->
            (* Main loop: forward client input with framing *)
            let recv_buffer = ref "" in
            let rec loop () =
              if not t.running then
                Lwt.return_unit
              else
                let buf = Bytes.create 4096 in
                let* n =
                  Lwt.catch
                    (fun () -> Lwt_unix.read client_fd buf 0 4096)
                    (fun _ -> Lwt.return 0)
                in

                if n = 0 then (
                  (* Client disconnected *)
                  let* () = Session.remove_client session client in
                  Lwt.return_unit
                ) else (
                  let data = Bytes.sub_string buf 0 n in
                  recv_buffer := !recv_buffer ^ data;

                  (* Parse framed messages *)
                  let rec parse_messages () =
                    match Protocol.try_parse_framed !recv_buffer with
                    | None -> Lwt.return_unit
                    | Some (msg, remaining) ->
                      recv_buffer := remaining;
                      let* () = Session.handle_client_input session ~client ~data:msg in
                      parse_messages ()
                  in
                  let* () = parse_messages () in
                  loop ()
                )
            in

            let* () = loop () in
            (* Socket may already be closed by session cleanup *)
            let* () = Lwt.catch (fun () -> Lwt_unix.close client_fd) (fun _ -> Lwt.return_unit) in
            Lwt.return_unit
      )
      (fun () -> Lwt.return_unit)
      (fun exn ->
        let error_msg = Printf.sprintf "Handshake error: %s" (Printexc.to_string exn) in
        let* () = Logs_lwt.err (fun m -> m "%s" error_msg) in
        let* _ = Lwt_unix.write_string client_fd (error_msg ^ "\n") 0 (String.length error_msg + 1) in
        Lwt_unix.close client_fd)
    in
    Lwt.return_unit

let rec accept_loop t =
  if not t.running then
    Lwt.return_unit
  else
    match t.server_socket with
    | None -> Lwt.return_unit
    | Some socket ->
      let* client_fd, client_addr = Lwt_unix.accept socket in
      let addr =
        match client_addr with
        | Unix.ADDR_UNIX s -> s
        | _ -> "unknown"
      in

      (* One independent coroutine per client *)
      Lwt.async (fun () -> handle_client t client_fd addr);

      accept_loop t

let cleanup_sessions t =
  let rec loop () =
    let* () = Lwt_unix.sleep 60.0 in
    if not t.running then
      Lwt.return_unit
    else
      let* () =
        Lwt_mutex.with_lock t.sessions_lock (fun () ->
          let dead = ref [] in
          Hashtbl.iter (fun id session ->
            if not (Session.is_alive session) &&
               List.length (Session.get_clients session) = 0 then
              dead := (id, session) :: !dead
          ) t.sessions;

          List.iter (fun (id, session) ->
            Hashtbl.remove t.sessions id;
            Lwt.async (fun () -> Session.shutdown session)
          ) !dead;

          Lwt.return_unit
        )
      in
      loop ()
  in
  loop ()

let start t =
  let* () = setup_socket t in
  t.running <- true;

  (* Start cleanup coroutine *)
  Lwt.async (fun () -> cleanup_sessions t);

  (* Main accept loop *)
  accept_loop t

let stop t =
  t.running <- false;

  (* Close socket *)
  (match t.server_socket with
   | Some s -> Lwt.async (fun () -> Lwt_unix.close s)
   | None -> ());

  (* Close all sessions *)
  let* () =
    Lwt_mutex.with_lock t.sessions_lock (fun () ->
      Hashtbl.fold (fun _ session acc ->
        let* () = Session.shutdown session in
        acc
      ) t.sessions Lwt.return_unit
    )
  in

  (* Flush audit logs *)
  Audit.close t.audit
