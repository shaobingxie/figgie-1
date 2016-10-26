open Core_kernel.Std
open Incr_dom.Std
open Vdom

module Username_with_class = struct
  type t = Username.t * string [@@deriving sexp_of]
  
  let span (u, c) =
    Node.span [Attr.class_ c] [Node.text (Username.to_string u)]
end

module Message = struct
  type t =
    | Order_reject of Protocol.Order.error
    | Cancel_reject of Protocol.Cancel.error
    | Chat of Username_with_class.t * string
    [@@deriving sexp_of]
end

module Model = struct
  type t =
    { messages : Message.t Fqueue.t
    ; is_connected : bool
    }
end

module Action = struct
  type t = Send_chat of string
end

let view (t : Model.t) ~inject =
  let nodes_of_message : Message.t -> _ =
    function
    | Order_reject reject ->
      [ Node.text
          (Protocol.Order.sexp_of_error reject |> Sexp.to_string)
      ]
    | Cancel_reject reject ->
      [ Node.text
          (Protocol.Cancel.sexp_of_error reject |> Sexp.to_string)
      ]
    | Chat (who, msg) ->
      [ Username_with_class.span who
      ; Node.text ": "
      ; Node.text msg
      ]
  in
  Node.div [Attr.id "historycmd"]
    [ Node.ul [Attr.id "history"]
        (List.map (Fqueue.to_list t.messages) ~f:(fun msg ->
          Node.li [] (nodes_of_message msg)))
    ; Widget.textbox ~id:Ids.cmdline
        ~f:(fun msg -> inject (Action.Send_chat msg))
        [ Attr.property "disabled"
            (Js.Unsafe.inject (Js.bool (not t.is_connected)))
        ]
    ]