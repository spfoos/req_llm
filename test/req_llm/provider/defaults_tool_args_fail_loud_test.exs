defmodule ReqLLM.Provider.DefaultsToolArgsFailLoudTest do
  @moduledoc """
  Unparseable tool-call arguments must pass through as the raw string instead
  of silently collapsing to %{}.

  A truncated or mangled streamed payload that becomes %{} executes the tool
  with empty arguments; the model then only sees the tool's own parameter
  error and has no evidence its payload was discarded, so it retries blind.
  Passing the raw string through makes the tool layer's JSON decode fail and
  return a parse error the model can react to.
  """
  use ExUnit.Case, async: true

  alias ReqLLM.Provider.Defaults
  alias ReqLLM.StreamChunk

  setup do
    %{model: %LLMDB.Model{provider: :openai, id: "gpt-4"}}
  end

  describe "default_decode_stream_event/2 with malformed arguments" do
    test "unparseable inline args become a raw-string tool_call chunk", %{model: model} do
      event = %{
        data: %{
          "choices" => [
            %{
              "delta" => %{
                "tool_calls" => [
                  %{
                    "id" => "call_1",
                    "type" => "function",
                    "index" => 0,
                    "function" => %{
                      "name" => "dispatch_parallel_agents",
                      "arguments" => ~s({"agents": [{"name")
                    }
                  }
                ]
              }
            }
          ]
        }
      }

      assert [%StreamChunk{type: :tool_call} = chunk] =
               Defaults.default_decode_stream_event(event, model)

      assert chunk.arguments == ~s({"agents": [{"name")
      assert chunk.metadata.invalid_arguments
      assert chunk.metadata.raw_arguments == ~s({"agents": [{"name")
    end

    test "empty-string args stay %{} (normal streaming prelude)", %{model: model} do
      event = %{
        data: %{
          "choices" => [
            %{
              "delta" => %{
                "tool_calls" => [
                  %{
                    "id" => "call_1",
                    "type" => "function",
                    "index" => 0,
                    "function" => %{"name" => "get_tasks", "arguments" => ""}
                  }
                ]
              }
            }
          ]
        }
      }

      assert [%StreamChunk{type: :tool_call} = chunk] =
               Defaults.default_decode_stream_event(event, model)

      assert chunk.arguments == %{}
      refute Map.has_key?(chunk.metadata, :invalid_arguments)
    end

    test "JSON null args stay %{} (no arguments, not malformed)", %{model: model} do
      event = %{
        data: %{
          "choices" => [
            %{
              "delta" => %{
                "tool_calls" => [
                  %{
                    "id" => "call_1",
                    "type" => "function",
                    "index" => 0,
                    "function" => %{"name" => "get_tasks", "arguments" => "null"}
                  }
                ]
              }
            }
          ]
        }
      }

      assert [%StreamChunk{type: :tool_call} = chunk] =
               Defaults.default_decode_stream_event(event, model)

      assert chunk.arguments == %{}
      refute Map.has_key?(chunk.metadata, :invalid_arguments)
    end

    test "valid JSON non-object args pass through raw", %{model: model} do
      event = %{
        data: %{
          "choices" => [
            %{
              "delta" => %{
                "tool_calls" => [
                  %{
                    "id" => "call_1",
                    "type" => "function",
                    "index" => 0,
                    "function" => %{"name" => "get_tasks", "arguments" => "[1, 2]"}
                  }
                ]
              }
            }
          ]
        }
      }

      assert [%StreamChunk{type: :tool_call} = chunk] =
               Defaults.default_decode_stream_event(event, model)

      assert chunk.arguments == "[1, 2]"
      assert chunk.metadata.invalid_arguments
    end
  end

  describe "decode_response_body_openai_format/2 with malformed arguments" do
    test "unparseable args survive on the wire-format tool call", %{model: model} do
      response_data = %{
        "id" => "chatcmpl-1",
        "choices" => [
          %{
            "message" => %{
              "tool_calls" => [
                %{
                  "id" => "call_1",
                  "type" => "function",
                  "function" => %{
                    "name" => "dispatch_parallel_agents",
                    "arguments" => ~s({"agents": [{"name")
                  }
                }
              ]
            },
            "finish_reason" => "tool_calls"
          }
        ]
      }

      {:ok, result} = Defaults.decode_response_body_openai_format(response_data, model)

      assert [tool_call] = result.message.tool_calls
      assert tool_call.function.arguments == ~s({"agents": [{"name")
    end
  end
end
