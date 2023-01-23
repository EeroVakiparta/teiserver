defmodule Teiserver.Bridge.DiscordBridge do
  @moduledoc """
  This is the module that receives discord events and passes them to the rest of Teiserver.
  """

  # use Alchemy.Cogs
  use Alchemy.Events
  alias Teiserver.{Room, Moderation}
  alias Teiserver.Bridge.{BridgeServer, MessageCommands, ChatCommands}
  alias Central.{Config}
  alias Central.Helpers.TimexHelper
  require Logger

  # Discord message ping: <@userid>

  @emoticon_map %{
    "🙂" => ":)",
    "😒" => ":s",
    "😦" => ":(",
    "😛" => ":p",
    "😄" => ":D",
  }

  @extra_text_emoticons %{
    ":S" => "😒",
    ":P" => "😛",
  }

  @text_to_emoticon_map @emoticon_map
    |> Map.new(fn {k, v} -> {v, k} end)
    |> Map.merge(@extra_text_emoticons)

  @spec get_text_to_emoticon_map() :: Map.t()
  def get_text_to_emoticon_map, do: @text_to_emoticon_map

  Events.on_DMChannel_create(:new_dm_channel)
  Events.on_message(:recv_message)

  @spec new_dm_channel(atom | %{:recipients => any, optional(any) => any}) :: :ok
  def new_dm_channel(dm_channel) do
    case dm_channel.recipients do
      [recipient] ->
        Central.cache_put(:discord_bridge_dm_cache, dm_channel.id, recipient["id"])
        Logger.info("Discord DM Channel #{dm_channel.id} set to #{recipient["id"]}")
        nil

      _ -> nil
    end
    :ok
  end

  @spec recv_message(atom | %{:attachments => any, optional(any) => any}) :: nil | :ok
  def recv_message(%Alchemy.Message{channel_id: channel_id, content: "$" <> _content} = message) do
    dm_sender = Central.cache_get(:discord_bridge_dm_cache, channel_id)

    if dm_sender != nil do
      MessageCommands.handle(message)
    else
      ChatCommands.handle(message)
    end
  end

  def recv_message(%Alchemy.Message{author: author, channel_id: channel_id, attachments: [], content: content} = message) do
    room = bridge_channel_to_room(channel_id)
    dm_sender = Central.cache_get(:discord_bridge_dm_cache, channel_id)

    cond do
      author.username == Application.get_env(:central, DiscordBridge)[:bot_name] ->
        nil

      dm_sender != nil ->
        MessageCommands.handle(message)

      room == "moderation-reports" ->
        nil

      room == "moderation-actions" ->
        nil

      String.contains?(content, "http:") ->
        nil

      String.contains?(content, "https:") ->
        nil

      Config.get_site_config_cache("teiserver.Bridge from discord") == false ->
        nil

      room != nil ->
        do_reply(message)

      true ->
        nil
    end
  end

  def recv_message(message) do
    cond do
      message.attachments != [] ->
        nil

      # We expected to be able to handle it but didn't, what's happening?
      true ->
        Logger.debug("Unhandled DiscordBridge event: #{Kernel.inspect message}")
    end
  end

  @spec new_infolog(Teiserver.Telemetry.Infolog.t()) :: any
  def new_infolog(infolog) do
    chan_result = Application.get_env(:central, DiscordBridge)[:bridges]
      |> Enum.filter(fn {_chan, room} -> room == "telemetry-infologs" end)

    chan = case chan_result do
      [{chan, _}] -> chan
      _ -> nil
    end

    post_to_discord = cond do
      infolog.metadata["shorterror"] == "Errorlog" -> false
      infolog.metadata["private"]    == true       -> false
      true -> true
    end

    if post_to_discord do
      host = Application.get_env(:central, CentralWeb.Endpoint)[:url][:host]
      url = "https://#{host}/teiserver/reports/infolog/#{infolog.id}"

      Alchemy.Client.send_message(
        chan,
        [
          "New infolog uploaded: #{infolog.metadata["errortype"]} `#{infolog.metadata["filename"]}`",
          "`#{infolog.metadata["shorterror"]}`",
          "Link: #{url}",
        ] |> Enum.join("\n"),
        []# Options
      )
    end
  end

  @spec new_report(Moderation.Report.t()) :: any
  def new_report(report) do
    chan_result = Application.get_env(:central, DiscordBridge)[:bridges]
      |> Enum.filter(fn {_chan, room} -> room == "moderation-reports" end)

    chan = case chan_result do
      [{chan, _}] -> chan
      _ -> nil
    end

    if chan do
      report = Moderation.get_report!(report.id, preload: [:reporter, :target])

      host = Application.get_env(:central, CentralWeb.Endpoint)[:url][:host]
      url = "https://#{host}/moderation/report?/target_id=#{report.target_id}"

      match_icon = cond do
        report.match_id == nil -> ""
        true -> ":crossed_swords:"
      end

      msg = "#{report.target.name} was reported by #{report.reporter.name} because #{report.type}/#{report.sub_type} #{match_icon} - #{report.extra_text} - #{url}"

      Alchemy.Client.send_message(
        chan,
        "Moderation report: #{msg}",
        []# Options
      )
    end
  end

  @spec new_action(Moderation.Action.t()) :: any
  def new_action(action) do
    action = Moderation.get_action!(action.id, preload: [:target])

    result = Application.get_env(:central, DiscordBridge)[:bridges]
      |> Enum.filter(fn {_chan, room} -> room == "moderation-actions" end)

    chan = case result do
      [{chan, _}] -> chan
      _ -> nil
    end

    post_to_discord = cond do
      action.restrictions == ["Bridging"] -> false
      action.reason == "Banned (Automod)" -> false
      chan == nil -> false
      true -> true
    end

    if post_to_discord do
      until = if action.expires do
        "Until: " <> TimexHelper.date_to_str(action.expires, format: :ymd_hms) <> " (UTC)"
      else
        "Permanent"
      end

      restriction_string = action.restrictions
        |> Enum.join(", ")

      msg = [
        "----------------------",
        "#{action.target.name} has been moderated.",
        "Reason: #{action.reason}",
        "Restriction(s): #{restriction_string}",
        until,
        "----------------------"
      ]
        |> List.flatten
        |> Enum.join("\n")
        |> String.replace("\n\n", "\n")

      Alchemy.Client.send_message(
        chan,
        msg,
        []# Options
      )
    end
  end

  defp do_reply(%Alchemy.Message{author: author, content: content, channel_id: channel_id, mentions: mentions}) do
    # Mentions come through encoded in a way we don't want to preserve, this substitutes them
    new_content = mentions
    |> Enum.reduce(content, fn (m, acc) ->
      String.replace(acc, "<@!#{m.id}>", m.username)
    end)
    |> String.replace(~r/<#[0-9]+> ?/, "")
    |> convert_emoticons
    |> String.split("\n")

    bridge_user_id = BridgeServer.get_bridge_userid()
    from_id = bridge_user_id

    # Temporarily disabled as the bridge echos itself
    # from_id = case User.get_userid_by_discord_id(author.id) do
    #   nil ->
    #     bridge_user_id
    #   userid ->
    #     case Client.get_client_by_id(userid) do
    #       nil ->
    #         bridge_user_id
    #       _ ->
    #         userid
    #     end
    # end

    message = if from_id == bridge_user_id do
      new_content
      |> Enum.map(fn row ->
        "#{author.username}: #{row}"
      end)
    else
      new_content
    end

    room = bridge_channel_to_room(channel_id)
    Room.send_message(from_id, room, message)
  end

  defp convert_emoticons(msg) do
    msg
    |> String.replace(Map.keys(@emoticon_map), fn emoji -> @emoticon_map[emoji] end)
  end

  defp bridge_channel_to_room(channel_id) do
    result = Application.get_env(:central, DiscordBridge)[:bridges]
    |> Enum.filter(fn {chan, _room} -> chan == channel_id end)

    case result do
      [{_, room}] -> room
      _ -> nil
    end
  end
end
