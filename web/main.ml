open Core_kernel.Std
open Async_kernel
open Async_rpc_kernel.Std
open Incr_dom
open Vdom

open Figgie
open Market

module Waiting = struct
  module Model = struct
    type t = { ready : Username.Set.t }
  end

  let set_player_readiness (t : Model.t) ~username ~is_ready =
    let apply = if is_ready then Set.add else Set.remove in
    { Model.ready = apply t.ready username }
end

module Playing = struct
  module Model = struct
    type t = {
      my_hand       : Size.t Card.Hand.t;
      other_hands   : Partial_hand.t Username.Map.t;
      market        : Book.t;
      trades        : (Order.t * Cpty.t) Fqueue.t;
      trades_scroll : Scrolling.Model.t;
      exchange      : Exchange.Model.t;
      clock         : Countdown.Model.t option;
    }
  end

  module Action = struct
    type t =
      | Market of Book.t
      | Hand of Size.t Card.Hand.t
      | Trade of Order.t * Cpty.t
      | Exchange of Exchange.Action.t
      | Scroll_trades of Scrolling.Action.t
      | Set_clock of Time_ns.t sexp_opaque
      | Clock of Countdown.Action.t
      [@@deriving sexp_of]
  end
end

module Logged_in = struct
  module Model = struct
    module Game = struct
      type t =
        | Lobby of
          { lobby : Lobby.t
          ; updates : Protocol.Lobby_update.t Pipe.Reader.t
          }
        | Waiting of Waiting.Model.t
        | Playing of Playing.Model.t
    end

    type t = {
      me     : Player.Persistent.t;
      others : Player.Persistent.t Username.Map.t;
      game   : Game.t;
    }
  end

  let update_round_if_playing (t : Model.t) ~f =
    match t.game with
    | Playing round -> { t with game = Playing (f round) }
    | Waiting _ | Lobby _ -> t

  let update_ready_if_waiting (t : Model.t) ~f =
    match t.game with
    | Playing _ | Lobby _ -> t
    | Waiting wait -> { t with game = Waiting (f wait) }

  let update_player (t : Model.t) ~username ~f =
    if Username.equal t.me.username username
    then { t with me = f t.me }
    else begin
      let others =
        Map.update t.others username
          ~f:(fun maybe_existing ->
            Option.value maybe_existing
              ~default:{ username; is_connected = true; score = Price.zero }
            |> f)
      in
      { t with others }
    end

  let player (t : Model.t) ~username =
    if Username.equal t.me.username username
    then Some t.me
    else Map.find t.others username

  module Action = struct
    type t =
      | I'm_ready of bool
      | Playing of Playing.Action.t
      | Lobby_update of Protocol.Lobby_update.t
      | Join_room of Lobby.Room.Id.t
      | Game_update  of Protocol.Game_update.t
      [@@deriving sexp_of]
  end
end

module Connected = struct
  module Model = struct
    type t = {
      conn : Rpc.Connection.t;
      host_and_port : Host_and_port.t;
      login : Logged_in.Model.t option;
    }
  end

  module Action = struct
    type t =
      | Start_login of Username.t
      | Finish_login of
        { username : Username.t
        ; lobby_pipe : Protocol.Lobby_update.t Pipe.Reader.t
        }
      | Logged_in of Logged_in.Action.t
      [@@deriving sexp_of]
  end
end

module App = struct
  module Model = struct
    module Connection_state = struct
      type t =
        | Not_connected of Connection_error.t option
        | Connecting of Host_and_port.t
        | Connected of Connected.Model.t
    end

    module For_status_line = struct
      type t =
        { input_error : bool
        ; connectbox_prefill : string option
        }
    end

    type t =
      { messages : Chat.Model.t
      ; state : Connection_state.t
      ; for_status_line : For_status_line.t
      }

    let initial =
      { messages = Chat.Model.initial
      ; state = Not_connected None
      ; for_status_line =
        { input_error = false
        ; connectbox_prefill = Url_vars.prefill_connect_to
        }
      }

    let get_conn t =
      match t.state with
      | Connected conn -> Some conn
      | _ -> None

    let cutoff = phys_equal
  end
  open Model

  module Action = struct
    type t =
      | Add_message of Chat.Message.t
      | Send_chat of string
      | Scroll_chat of Scrolling.Action.t
      | Status_line of Status_line.Action.t
      | Finish_connecting of
        { host_and_port : Host_and_port.t
        ; conn : Rpc.Connection.t
        }
      | Connection_failed
      | Connection_lost
      | Connected of Connected.Action.t
      [@@deriving sexp_of]

    let should_log _ = false

    let logged_in lact = Connected (Logged_in lact)
    let playing pact   = logged_in (Playing pact)
    let clock cdact    = playing (Clock cdact)
  end

  module State = struct
    type t = { schedule : Action.t -> unit }
  end

  let apply_playing_action
      (t : Playing.Action.t)
      ~(schedule : Action.t -> _)
      ~conn
      ~(login : Logged_in.Model.t)
      (round : Playing.Model.t)
    =
    match t with
    | Market market ->
      let other_hands =
        Map.mapi round.other_hands ~f:(fun ~key:username ~data:hand ->
          Card.Hand.foldi market ~init:hand
            ~f:(fun suit hand book ->
              let size =
                List.sum (module Size) book.sell ~f:(fun order ->
                  if Username.equal order.owner username
                  then order.size
                  else Size.zero)
              in
              Partial_hand.selling hand ~suit ~size))
      in
      { round with market; other_hands }
    | Hand hand ->
      { round with my_hand = hand }
    | Set_clock end_time ->
      let clock =
        Countdown.of_end_time
          ~schedule:(fun cdact -> schedule (Action.clock cdact))
          end_time
      in
      { round with clock = Some clock }
    | Clock cdact ->
      let clock =
        Option.map round.clock ~f:(fun c ->
          Countdown.Action.apply cdact
            ~schedule:(fun cdact -> schedule (Action.clock cdact))
            c)
      in
      { round with clock }
    | Trade (order, with_) ->
      let trades = Fqueue.enqueue round.trades (order, with_) in
      let other_hands =
        Map.mapi round.other_hands ~f:(fun ~key:username ~data:hand ->
          let traded dir =
            Partial_hand.traded
              hand ~suit:order.symbol ~size:order.size ~dir
          in
          if Username.equal username order.owner
          then traded order.dir
          else if Username.equal username with_
          then traded (Dir.other order.dir)
          else hand)
      in
      { round with trades; other_hands }
    | Scroll_trades act ->
      { round with
        trades_scroll = Scrolling.apply_action round.trades_scroll act
      }
    | Exchange exact ->
      { round with
        exchange =
          Exchange.apply_action exact round.exchange
            ~my_name:login.me.username
            ~conn
            ~market:round.market
            ~add_message:(fun msg -> schedule (Add_message msg))
      }

  let apply_logged_in_action
      (t : Logged_in.Action.t)
      ~(schedule : Action.t -> _) ~conn
      (login : Logged_in.Model.t) : Logged_in.Model.t
    =
    match t with
    | I'm_ready readiness ->
      begin match login.game with
      | Waiting wait ->
        don't_wait_for begin
          Rpc.Rpc.dispatch_exn Protocol.Is_ready.rpc conn readiness
          >>| function
          | Ok ()
          | Error `Already_playing
          | Error `Not_logged_in
          | Error `Not_in_a_room -> ()
        end;
        { login with game =
            Waiting
              (Waiting.set_player_readiness wait
                ~username:login.me.username
                ~is_ready:readiness)
        }
      | _ -> login
      end
    | Playing pact ->
      begin match login.game with
      | Playing round ->
        { login with game =
            Playing (apply_playing_action pact ~schedule ~conn ~login round)
        }
      | _ -> login
      end
    | Lobby_update up ->
      begin match login.game with
      | Lobby { lobby; updates } ->
        begin match up with
        | Chat (username, msg) ->
          let is_me = Username.equal username login.me.username in
          schedule (Add_message (Chat { username; is_me; msg }));
          login
        | Lobby_update up ->
          begin match up with
          | Other_login username ->
            schedule (Add_message (Player_room_event
              { username; room_id = None; event = Joined }
            ))
          | Other_disconnect username ->
            schedule (Add_message (Player_room_event
              { username; room_id = None; event = Disconnected }
            ))
          | Player_event { username; room_id; event } ->
            schedule (Add_message (Player_room_event
              { username; room_id = Some room_id; event }
            ))
          | _ -> ()
          end;
          let new_lobby = Lobby.Update.apply up lobby in
          { login with game = Lobby { lobby = new_lobby; updates } }
        end
      | _ -> login
      end
    | Join_room id ->
      don't_wait_for begin
        Rpc.Pipe_rpc.dispatch_exn Protocol.Join_room.rpc conn id
        >>= fun (pipe, _metadata) ->
        begin match login.game with
        | Lobby { lobby = _; updates } -> Pipe.close_read updates
        | _ -> ()
        end;
        schedule (Add_message (Joined_room id));
        Pipe.iter_without_pushback pipe
          ~f:(fun update -> schedule (Action.logged_in (Game_update update)))
      end;
      { login with game = Waiting { ready = Username.Set.empty } }
    | Game_update up ->
      let just_schedule act = schedule act; login in
      match up with
      | Room_snapshot room ->
        Map.fold room.users ~init:login ~f:(fun ~key:_ ~data:user login ->
            Logged_in.update_player login ~username:user.username
              ~f:(fun p -> { p with is_connected = user.is_connected })
          )
      | Hand hand     -> just_schedule (Action.playing (Hand hand))
      | Market market -> just_schedule (Action.playing (Market market))
      | Broadcast (Exec (order, exec)) ->
        List.iter exec.fully_filled ~f:(fun filled_order ->
          schedule (Action.playing (Trade
            ( { order
                with size = filled_order.size; price = filled_order.price }
            , filled_order.owner
            ))));
        Option.iter exec.partially_filled ~f:(fun partial_fill ->
          schedule (Action.playing (Trade
            ( { order with size = partial_fill.filled_by }
            , partial_fill.original_order.owner
            ))));
        don't_wait_for begin
          let%map () =
            Rpc.Rpc.dispatch_exn Protocol.Get_update.rpc conn Market
            >>| Protocol.playing_exn
          and () =
            Rpc.Rpc.dispatch_exn Protocol.Get_update.rpc conn Hand
            >>| Protocol.playing_exn
          in
          ()
        end;
        login
      | Broadcast (Player_room_event { username; event }) ->
        schedule (Add_message (Player_room_event
          { username; room_id = None; event }
        ));
        let is_connected =
          match event with
          | Joined -> true
          | Disconnected -> false
        in
        Logged_in.update_player login ~username
          ~f:(fun t -> { t with is_connected })
      | Broadcast New_round ->
        schedule (Add_message New_round);
        don't_wait_for begin
          (* Sample the time *before* we send the RPC. Then the game end
             time we get is actually roughly "last time we can expect to
             send an RPC and have it arrive before the game ends". *)
          let current_time = Time_ns.now () in
          Rpc.Rpc.dispatch_exn Protocol.Time_remaining.rpc conn ()
          >>| function
          | Error #Protocol.not_playing -> ()
          | Ok remaining ->
            let end_time = Time_ns.add current_time remaining in
            schedule (Action.playing (Set_clock end_time))
        end;
        { login with game =
            Playing
              { my_hand = Card.Hand.create_all Size.zero
              ; other_hands =
                  Map.map login.others ~f:(fun _ ->
                    Partial_hand.create_unknown Params.num_cards_per_hand)
              ; market = Book.empty
              ; trades = Fqueue.empty
              ; trades_scroll = Scrolling.Model.create ~id:Ids.tape
              ; exchange = Exchange.Model.initial
              ; clock = None
              }
        }
      | Broadcast (Round_over results) ->
        schedule (Add_message (Round_over results));
        { login with game = Waiting { ready = Username.Set.empty } }
      | Broadcast (Scores scores) ->
        Map.fold scores ~init:login
          ~f:(fun ~key:username ~data:score login ->
            Logged_in.update_player login ~username
              ~f:(fun player -> { player with score }))
      | Broadcast (Chat (username, msg)) ->
        let is_me = Username.equal username login.me.username in
        just_schedule (Add_message (Chat { username; is_me; msg }))
      | Broadcast (Out _) ->
        don't_wait_for begin
          Rpc.Rpc.dispatch_exn Protocol.Get_update.rpc conn Market
          >>| Protocol.playing_exn
        end;
        login
      | Broadcast (Player_ready { who; is_ready }) ->
        Logged_in.update_ready_if_waiting login ~f:(fun wait ->
          Waiting.set_player_readiness wait ~username:who ~is_ready)

  let apply_connected_action
      (t : Connected.Action.t)
      ~(schedule : Action.t -> _)
      (conn : Connected.Model.t) : Connected.Model.t
    =
    match t with
    | Start_login username ->
      don't_wait_for begin
        Rpc.Rpc.dispatch_exn Protocol.Login.rpc conn.conn username
        >>= function
        | Error (`Already_logged_in | `Invalid_username) -> Deferred.unit
        | Ok () ->
          Rpc.Pipe_rpc.dispatch_exn Protocol.Get_lobby_updates.rpc
            conn.conn ()
          >>= fun (pipe, _pipe_metadata) ->
          schedule (Connected (Finish_login { username; lobby_pipe = pipe }));
          Pipe.iter_without_pushback pipe
            ~f:(fun update -> schedule (Action.logged_in (Lobby_update update)))
      end;
      conn
    | Finish_login { username; lobby_pipe } ->
      let me : Player.Persistent.t =
        { username; is_connected = true; score = Price.zero }
      in
      let logged_in =
        { Logged_in.Model.me; others = Username.Map.empty
        ; game = Lobby { lobby = Lobby.empty; updates = lobby_pipe }
        }
      in
      { conn with login = Some logged_in }
    | Logged_in lact ->
      begin match conn.login with
      | None -> conn
      | Some logged_in ->
        let logged_in =
          apply_logged_in_action lact ~schedule ~conn:conn.conn logged_in
        in
        { conn with login = Some logged_in }
      end

  let apply_action (action : Action.t) (model : Model.t) (state : State.t) =
    match action with
    | Add_message msg ->
      { model with messages = Chat.Model.add_message model.messages msg }
    | Send_chat msg ->
      Option.iter (get_conn model) ~f:(fun { conn; _ } ->
        don't_wait_for begin
          Rpc.Rpc.dispatch_exn Protocol.Chat.rpc conn msg
          >>| function
          | Error `Chat_disabled ->
            state.schedule (Action.Add_message (Chat_failed `Chat_disabled))
          | Error `Not_logged_in ->
            state.schedule (Action.Add_message (Chat_failed `Not_logged_in))
          | Ok () -> ()
        end
      );
      model
    | Scroll_chat act ->
      { model with messages = Chat.apply_scrolling_action model.messages act }
    | Status_line Input_error ->
      { model with for_status_line =
        { model.for_status_line with input_error = true }
      }
    | Status_line Input_ok ->
      { model with for_status_line =
        { model.for_status_line with input_error = false }
      }
    | Status_line (Log_in username) ->
      state.schedule (Connected (Start_login username));
      { model with for_status_line =
        { model.for_status_line with input_error = false }
      }
    | Status_line (Start_connecting_to host_and_port) ->
      let host, port = Host_and_port.tuple host_and_port in
      don't_wait_for begin
        Async_js.Rpc.Connection.client
          ~address:(Host_and_port.create ~host ~port)
          ()
        >>| function
        | Error _error ->
          state.schedule Connection_failed
        | Ok conn ->
          state.schedule (Finish_connecting { host_and_port; conn });
          don't_wait_for (
            Rpc.Connection.close_finished conn
            >>| fun () ->
            state.schedule Connection_lost
          )
      end;
      { model with
        state = Connecting host_and_port
      ; for_status_line =
        { input_error = false
        ; connectbox_prefill = Some (Host_and_port.to_string host_and_port)
        }
      }
    | Finish_connecting { host_and_port; conn } ->
      state.schedule (Add_message (Connected_to_server host_and_port));
      { model with state = Connected { host_and_port; conn; login = None } }
    | Connection_lost ->
      state.schedule (Add_message Disconnected_from_server);
      { model with state = Not_connected (Some Connection_lost) }
    | Connection_failed ->
      { model with state = Not_connected (Some Failed_to_connect) }
    | Connected cact ->
      begin match model.state with
      | Connected conn ->
        let conn =
          apply_connected_action cact ~schedule:state.schedule conn
        in
        { model with state = Connected conn }
      | _ -> model
      end

  let chat_view (model : Model.t) ~(inject : Action.t -> _) =
    let chat_inject : Chat.Action.t -> _ = function
      | Send_chat msg ->
        inject (Send_chat msg)
      | Scroll_chat act ->
        inject (Scroll_chat act)
    in
    Chat.view model.messages
      ~is_connected:(Option.is_some (get_conn model))
      ~inject:chat_inject

  let status_line (model : Model.t) : Status_line.Model.t =
    match model.state with
    | Not_connected conn_error ->
      Not_connected
        { conn_error
        ; input_error = model.for_status_line.input_error
        ; connectbox_prefill = model.for_status_line.connectbox_prefill
        }
    | Connecting hp -> Connecting hp
    | Connected { host_and_port; login; _ } ->
      begin match login with
      | None -> Connected host_and_port
      | Some login ->
          Logged_in
            { connected_to = host_and_port
            ; username = login.me.username
            ; room_name = None
            ; clock =
                match login.game with
                | Playing { clock; _ } -> clock
                | _ -> None
            }
      end

  let view (incr_model : Model.t Incr.t) ~(inject : Action.t -> _) =
    let open Incr.Let_syntax in
    let%map model = incr_model in
    let view bits_in_between =
      Node.body
        [ Hotkeys.Global.handler ]
        [ Node.div [Attr.id "container"] (
            [ [ Status_line.view
                  (status_line model)
                  ~inject:(fun act -> inject (Status_line act))
              ]
            ; bits_in_between 
            ; [chat_view model ~inject]
            ] |> List.concat
          )
        ]
    in
    match get_conn model with
    | None | Some { login = None; _ } -> view []
    | Some { login = Some login; conn; host_and_port = _ } ->
      let my_name = login.me.username in
      let exchange_inject act = inject (Action.playing (Exchange act)) in
      begin match login.game with
      | Playing { my_hand; other_hands; market; trades; _ } ->
        let me =
          { Player.pers = login.me
          ; hand = Partial_hand.create_known my_hand
          }
        in
        let others =
          Map.merge login.others other_hands ~f:(fun ~key:_ ->
            function
            | `Both (pers, hand) -> Some { Player.pers; hand }
            | `Left _ | `Right _ -> None)
        in
        let players = Map.add others ~key:my_name ~data:me in
        [ Exchange.view ~my_name ~market ~trades
            ~players:(Set.of_map_keys players)
            ~inject:exchange_inject
        ; Infobox.playing ~others ~me
        ] |> view
      | Waiting { ready } ->
        [ Exchange.view
            ~my_name
            ~market:Book.empty
            ~trades:Fqueue.empty
            ~players:Username.Set.empty
            ~inject:exchange_inject
        ; Infobox.waiting
            ~inject_I'm_ready:(fun readiness ->
              inject (Action.logged_in (I'm_ready readiness)))
            ~others:login.others
            ~me:login.me
            ~who_is_ready:ready
        ] |> view
      | Lobby { lobby; updates = _ } ->
        [ Lobby_view.view lobby
            ~my_name
            ~inject:(function
              | Join_room id ->
                inject (Action.logged_in (Join_room id))
              | Delete_room id ->
                don't_wait_for begin
                  let open Async_kernel in
                  Rpc.Rpc.dispatch_exn Protocol.Delete_room.rpc conn id
                  >>| function
                  | Error (`No_such_room | `Room_in_use) -> ()
                  | Ok () -> ()
                end;
                Event.Ignore
            )
        ] |> view
      end

  let on_startup ~schedule _model =
    Option.iter Url_vars.auto_connect_to
      ~f:(fun hp -> schedule (Action.Status_line (Start_connecting_to hp)));
    return { State.schedule }

  let on_display ~(old : Model.t) (new_ : Model.t) (state : State.t) =
    begin match get_conn new_ with
    | Some { login = Some { game = Playing p; _ }; _ } ->
      Scrolling.on_display p.trades_scroll
        ~schedule:(fun act ->
          state.schedule (Action.playing (Scroll_trades act)))
    | _ -> ()
    end;
    Status_line.on_display ~old:(status_line old) (status_line new_);
    Chat.on_display
      ~old:old.messages
      new_.messages
      ~schedule_scroll:(fun act -> state.schedule (Scroll_chat act))

  let update_visibility model = model
end

let () =
  Start_app.simple
    ~initial_model:App.Model.initial
    (module App)
