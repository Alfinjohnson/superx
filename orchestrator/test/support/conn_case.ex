defmodule Orchestrator.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Plug.Test` and also
  import other functionality to make it easier
  to build and query Plug connections.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # Import conveniences for testing with connections
      import Plug.Conn
      import Plug.Test

      import Orchestrator.Factory

      # Helper to build a test connection with JSON body
      def build_conn(method, path, body \\ nil) do
        body_string = if body, do: Jason.encode!(body), else: ""

        conn(method, path, body_string)
        |> put_req_header("content-type", "application/json")
      end

      # Helper to build RPC connection
      def build_rpc_conn do
        conn(:post, "/rpc", "")
        |> put_req_header("content-type", "application/json")
      end

      # Helper to post RPC request
      def post_rpc(conn, body) do
        conn
        |> Map.put(:body_params, body)
        |> Orchestrator.Router.call(Orchestrator.Router.init([]))
      end

      # Helper to JSON decode response body
      def json_response(conn, status) do
        assert conn.status == status
        Jason.decode!(conn.resp_body)
      end

      # Helper to make JSON POST request through router
      def json_post(path, body) do
        conn = conn(:post, path, Jason.encode!(body))
               |> put_req_header("content-type", "application/json")

        Orchestrator.Router.call(conn, Orchestrator.Router.init([]))
      end
    end
  end

  setup tags do
    Orchestrator.DataCase.setup_persistence(tags)
    :ok
  end
end
