defmodule Aliyun.Oss.Client.Request do
  import Aliyun.Oss.Config, only: [access_key_id: 0, access_key_secret: 0]

  alias Aliyun.Oss.Client.Request

  @enforce_keys [:host, :path, :resource]
  defstruct verb: "GET",
            host: nil,
            path: nil,
            resource: nil,
            query_params: %{},
            sub_resources: %{},
            body: "",
            headers: %{}

  @default_content_type "application/octet-stream"

  def build(init_req = %{host: host, path: path, resource: resource}) do
    %Request{host: host, path: path, resource: resource}
    |> Map.merge(init_req)
    |> ensure_essential_headers
  end

  def build_signed(init_req = %{}) do
    build(init_req)
    |> set_authorization_header()
  end

  def gen_signature(%Request{
         verb: verb,
         resource: resource,
         sub_resources: sub_resources,
         headers:
           headers = %{
             "Content-Type" => content_type,
             "Content-MD5" => md5,
             "Date" => date
           }
       }) do
    build_string_to_sign(%{
      verb: verb,
      content_md5: md5,
      content_type: content_type,
      date: date,
      canonicalized_oss_headers: canonicalize_oss_headers(headers),
      canonicalized_resource: canonicalize_resource(resource, sub_resources)
    })
    |> Aliyun.Util.Sign.sign(access_key_secret())
  end

  def gen_signature(init_req = %{}), do: init_req |> build() |> gen_signature()

  def query_url(%Request{host: host, path: path, query_params: query_params, sub_resources: sub_resources}) do
    URI.to_string(%URI{
      scheme: "https",
      host: host,
      path: path,
      query: Map.merge(query_params, sub_resources) |> URI.encode_query()
    })
  end

  defp ensure_essential_headers(req) do
    headers =
      req.headers
      |> Map.put_new("Host", req.host)
      |> Map.put_new_lazy("Content-Type", fn -> get_content_type(req) end)
      |> Map.put_new_lazy("Content-MD5", fn -> calc_content_md5(req) end)
      |> Map.put_new_lazy("Content-Length", fn -> byte_size(req.body) end)
      |> Map.put_new_lazy("Date", fn -> Aliyun.Util.Time.gmt_now() end)

    %Request{req | headers: headers}
  end

  defp set_authorization_header(req = %Request{}) do
    update_in(req.headers["Authorization"], fn _ -> "OSS " <> access_key_id() <> ":" <> gen_signature(req) end)
  end

  defp canonicalize_resource(resource, nil), do: resource
  defp canonicalize_resource(resource, sub_resources) do
    case sub_resources |> Stream.map(&encode_param/1) |> Enum.join("&") do
      "" -> resource
      query_string -> resource <> "?" <> query_string
    end
  end

  defp encode_param(param) do
    case param do
      {k, nil} -> k
      {k, v} -> "#{k}=#{v}"
    end
  end

  defp canonicalize_oss_headers(headers) do
    case headers
         |> Stream.filter(fn {h, _} ->
           Regex.match?(~r/^x-oss-/i, to_string(h))
         end)
         |> Stream.map(fn {h, v} ->
           (h |> to_string() |> String.downcase()) <> ":" <> to_string(v)
         end)
         |> Enum.join("\n") do
      "" -> ""
      str -> str <> "\n"
    end
  end

  defp get_content_type(%Request{resource: resource}) do
    case Path.extname(resource) do
      "." <> name -> MIME.type(name)
      _ -> @default_content_type
    end
  end

  defp build_string_to_sign(%{
         verb: verb,
         content_md5: content_md5,
         content_type: content_type,
         date: date,
         canonicalized_oss_headers: headers,
         canonicalized_resource: resource
       }) do
    verb <> "\n" <>
    content_md5 <> "\n" <>
    content_type <> "\n" <>
    date <> "\n" <>
    headers <> resource
  end

  defp calc_content_md5(%Request{body: ""}), do: ""
  defp calc_content_md5(%Request{body: body}) do
    :crypto.hash(:md5, body) |> Base.encode64()
  end
end
