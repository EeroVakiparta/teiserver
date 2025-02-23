defmodule Teiserver.Protocols.Spring.SpringPartyTest do
  use Teiserver.ServerCase, async: false
  alias Teiserver.Protocols.SpringIn
  alias Teiserver.Account.PartyLib

  alias Teiserver.Support.Polling

  import Teiserver.TeiserverTestLib,
    only: [auth_setup: 0, _send_raw: 2, _recv_until: 1]

  defp setup_user(_context) do
    %{socket: socket, user: user} = auth_setup()
    {:ok, socket: socket, user: user}
  end

  describe "create" do
    setup [:setup_user]

    test "create", %{socket: socket} do
      assert create_party!(socket) != nil
    end

    test "cannot create when in a party", %{socket: socket} do
      create_party!(socket)
      create_party(socket)
      assert {"NO", _, _} = _recv_until(socket) |> parse_in_message()
    end
  end

  describe "invite" do
    setup do
      {:ok, socket: socket1, user: user1} = setup_user(nil)
      {:ok, socket: socket2, user: user2} = setup_user(nil)
      # absorb the broadcasted message that another player is online
      "ADDUSER " <> _ = _recv_until(socket1)
      {:ok, socket1: socket1, user1: user1, socket2: socket2, user2: user2}
    end

    test "online player", %{socket1: sock1, socket2: sock2, user2: user2} do
      party_id = create_party!(sock1)
      invite_to_party!(sock1, user2.name)

      assert {"s.party.invited_to_party", [^party_id, _], _} =
               _recv_until(sock2) |> parse_in_message()
    end

    test "invalid player", %{socket1: sock1} do
      create_party!(sock1)
      invite_to_party(sock1, "lolnope-this-is-not-a-username-for-party")

      assert {"NO", _, _} = _recv_until(sock1) |> parse_in_message()
    end

    test "offline player", %{socket1: sock1, user2: user2} do
      Teiserver.Client.disconnect(user2.id)
      assert "REMOVEUSER " <> _ = _recv_until(sock1)
      create_party!(sock1)
      invite_to_party(sock1, user2.name)

      assert {"NO", %{"msg" => "user not connected"}, _} =
               _recv_until(sock1) |> parse_in_message()
    end
  end

  describe "handle invite" do
    setup do
      {:ok, socket: socket1, user: user1} = setup_user(nil)
      {:ok, socket: socket2, user: user2} = setup_user(nil)

      # absorb the broadcasted message that another player is online
      "ADDUSER " <> _ = _recv_until(socket1)

      party_id = create_party!(socket1)
      invite_to_party!(socket1, user2.name)

      assert {"s.party.invited_to_party", [^party_id, _], _} =
               _recv_until(socket2) |> parse_in_message()

      {:ok, socket1: socket1, user1: user1, socket2: socket2, user2: user2, party_id: party_id}
    end

    test "accept invite", %{socket1: sock1, user2: user2, socket2: sock2, party_id: party_id} do
      accept_invite!(sock2, party_id)

      assert {"s.party.joined_party", [^party_id, username2], _} =
               _recv_until(sock1) |> parse_in_message()

      assert username2 == user2.name
    end

    test "must be in party", ctx do
      invite_to_party(ctx.socket2, ctx.user1.name)
      assert {"NO", _, _} = _recv_until(ctx.socket2) |> parse_in_message()
    end

    test "decline invite", %{socket1: sock1, user2: user2, socket2: sock2, party_id: party_id} do
      decline_invite!(sock2, party_id)

      assert {"s.party.invite_cancelled", [^party_id, username2], _} =
               _recv_until(sock1) |> parse_in_message()

      assert username2 == user2.name

      # the invite is now invalid
      accept_invite(sock2, party_id)
      assert {"NO", _, _} = _recv_until(sock2) |> parse_in_message()
    end
  end

  describe "leaving parties" do
    setup do
      {:ok, socket: socket1, user: user1} = setup_user(nil)
      {:ok, socket: socket2, user: user2} = setup_user(nil)

      # absorb the broadcasted message that another player is online
      "ADDUSER " <> _ = _recv_until(socket1)

      party_id = create_party!(socket1)
      invite_to_party!(socket1, user2.name)

      assert {"s.party.invited_to_party", [^party_id, _], _} =
               _recv_until(socket2) |> parse_in_message()

      accept_invite!(socket2, party_id)

      assert {"s.party.joined_party", [^party_id, _], _} =
               _recv_until(socket1) |> parse_in_message()

      {:ok, socket1: socket1, user1: user1, socket2: socket2, user2: user2, party_id: party_id}
    end

    test "leave party", %{socket1: sock1, user2: user2, socket2: sock2, party_id: party_id} do
      leave_party!(sock2)

      assert {"s.party.left_party", [^party_id, username], _} =
               _recv_until(sock1) |> parse_in_message()

      assert username == user2.name
    end

    test "leave party via web", ctx do
      Teiserver.Account.leave_party(ctx.party_id, ctx.user2.id)
      party_id = ctx.party_id
      user2 = ctx.user2.name
      assert {"s.party.left_party", [^party_id, ^user2], _} =
               _recv_until(ctx.socket1) |> parse_in_message()

      assert {"s.party.left_party", [^party_id, ^user2], _} =
               _recv_until(ctx.socket2) |> parse_in_message()
    end
  end

  defp create_party(socket) do
    msg_id = :rand.uniform(1_000_000) |> to_string()
    _send_raw(socket, "##{msg_id} c.party.create_new_party\n")
  end

  defp create_party!(socket) do
    create_party(socket)

    [ok, joined] = _recv_until(socket) |> parse_in_messages()

    assert {"OK", %{"party_id" => party_id}, _} = ok
    assert {"s.party.joined_party", [^party_id, _], _} = joined

    Polling.poll_until_some(fn ->
      PartyLib.get_party(party_id)
    end)

    party_id
  end

  defp invite_to_party(socket, username) do
    msg_id = :rand.uniform(1_000_000) |> to_string()
    _send_raw(socket, "##{msg_id} c.party.invite_to_party #{username}\n")
  end

  defp invite_to_party!(socket, username) do
    invite_to_party(socket, username)
    assert {"OK", _, _} = _recv_until(socket) |> parse_in_message()
  end

  defp accept_invite(socket, party_id) do
    msg_id = :rand.uniform(1_000_000) |> to_string()
    _send_raw(socket, "##{msg_id} c.party.accept_invite_to_party #{party_id}\n")
  end

  defp accept_invite!(socket, party_id) do
    accept_invite(socket, party_id)
    [ok, joined] = _recv_until(socket) |> parse_in_messages()
    assert {"OK", _, _} = ok
    assert {"s.party.joined_party", [^party_id, _], _} = joined
  end

  defp decline_invite(socket, party_id) do
    msg_id = :rand.uniform(1_000_000) |> to_string()
    _send_raw(socket, "##{msg_id} c.party.decline_invite_to_party #{party_id}\n")
  end

  defp decline_invite!(socket, party_id) do
    decline_invite(socket, party_id)
    assert {"OK", _, _} = _recv_until(socket) |> parse_in_message()
  end

  defp leave_party(socket) do
    msg_id = :rand.uniform(1_000_000) |> to_string()
    _send_raw(socket, "##{msg_id} c.party.leave_current_party\n")
  end

  defp leave_party!(socket) do
    leave_party(socket)
    assert {"OK", _, _} = _recv_until(socket) |> parse_in_message()
  end

  defp parse_in_messages(raw) do
    String.split(raw, "\n") |> Enum.reject(&(&1 == "")) |> Enum.map(&parse_in_message/1)
  end

  defp parse_in_message(raw) do
    case SpringIn.parse_in_message(raw) do
      nil -> nil
      {cmd, args, ""} -> parse_args(nil, cmd, args)
      {cmd, args, msg_id} -> parse_args(msg_id, cmd, args)
    end
  end

  defp parse_args(msg_id, cmd, raw_args) when cmd in ["NO", "OK"] do
    args =
      String.split(raw_args, "\t")
      |> Enum.reduce(%{}, fn frag, m ->
        [k, v] = String.split(frag, "=")
        Map.put(m, String.trim(k), String.trim(v))
      end)

    {cmd, args, msg_id}
  end

  defp parse_args(msg_id, cmd, raw_args) do
    args = String.split(raw_args) |> Enum.map(&String.trim/1)
    {cmd, args, msg_id}
  end
end
