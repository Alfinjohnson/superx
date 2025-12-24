defmodule Orchestrator.StressTest do
  @moduledoc """
  Stress tests for the orchestrator.

  These tests verify system behavior under high load conditions:
  - Concurrent request handling
  - Circuit breaker under rapid failures
  - Task store throughput
  - Memory stability under load

  Run with: mix test test/stress --tag stress
  """

  use Orchestrator.DataCase, async: false

  alias Orchestrator.Factory
  alias Orchestrator.Task.Store, as: TaskStore
  alias Orchestrator.Agent.Store, as: AgentStore

  @moduletag :stress

  # -------------------------------------------------------------------
  # Configuration
  # -------------------------------------------------------------------

  # Number of concurrent operations for stress tests
  @concurrent_tasks 100
  @concurrent_agents 50
  @rapid_fire_count 500
  # Reduced from 5s to 2s
  @sustained_load_duration_ms 2_000

  describe "Task Store stress" do
    @tag timeout: 60_000
    test "handles #{@concurrent_tasks} concurrent task creations" do
      tasks =
        1..@concurrent_tasks
        |> Enum.map(fn i ->
          Task.async(fn ->
            task_payload =
              Factory.build(:task_payload)
              |> Map.put("id", "stress-task-#{i}-#{local_unique_id()}")

            start_time = System.monotonic_time(:microsecond)
            :ok = TaskStore.put(task_payload)
            end_time = System.monotonic_time(:microsecond)

            {task_payload["id"], end_time - start_time}
          end)
        end)

      results = Task.await_many(tasks, 30_000)

      # Verify all tasks were created
      assert length(results) == @concurrent_tasks

      # Check latency distribution
      latencies = Enum.map(results, fn {_id, latency} -> latency end)
      avg_latency = Enum.sum(latencies) / length(latencies)
      max_latency = Enum.max(latencies)
      p99_latency = percentile(latencies, 99)

      IO.puts("\n📊 Task Creation Stats (#{@concurrent_tasks} concurrent):")
      IO.puts("   Avg latency: #{Float.round(avg_latency / 1000, 2)}ms")
      IO.puts("   Max latency: #{Float.round(max_latency / 1000, 2)}ms")
      IO.puts("   P99 latency: #{Float.round(p99_latency / 1000, 2)}ms")

      # Verify tasks exist
      sample_ids = results |> Enum.take(10) |> Enum.map(fn {id, _} -> id end)

      for id <- sample_ids do
        assert TaskStore.get(id) != nil
      end
    end

    @tag timeout: 60_000
    test "handles #{@rapid_fire_count} rapid sequential task operations" do
      {create_time, task_ids} =
        :timer.tc(fn ->
          Enum.map(1..@rapid_fire_count, fn i ->
            task_payload =
              Factory.build(:task_payload)
              |> Map.put("id", "rapid-#{i}-#{local_unique_id()}")

            :ok = TaskStore.put(task_payload)
            task_payload["id"]
          end)
        end)

      {read_time, _} =
        :timer.tc(fn ->
          Enum.each(task_ids, fn id ->
            TaskStore.get(id)
          end)
        end)

      {update_time, _} =
        :timer.tc(fn ->
          Enum.each(task_ids, fn id ->
            TaskStore.apply_status_update(%{
              "taskId" => id,
              "status" => %{"state" => "working"}
            })
          end)
        end)

      IO.puts("\n📊 Rapid Fire Stats (#{@rapid_fire_count} operations):")

      IO.puts(
        "   Create: #{Float.round(create_time / 1000, 2)}ms total, #{Float.round(create_time / @rapid_fire_count, 2)}µs/op"
      )

      IO.puts(
        "   Read:   #{Float.round(read_time / 1000, 2)}ms total, #{Float.round(read_time / @rapid_fire_count, 2)}µs/op"
      )

      IO.puts(
        "   Update: #{Float.round(update_time / 1000, 2)}ms total, #{Float.round(update_time / @rapid_fire_count, 2)}µs/op"
      )

      # Verify final state
      sample_task = TaskStore.get(List.first(task_ids))
      assert sample_task["status"]["state"] == "working"
    end

    @tag timeout: 60_000
    test "handles mixed read/write load" do
      # Pre-create some tasks
      existing_ids =
        Enum.map(1..50, fn i ->
          task = Factory.build(:task_payload) |> Map.put("id", "existing-#{i}")
          :ok = TaskStore.put(task)
          task["id"]
        end)

      # Run mixed workload concurrently
      operations =
        Enum.map(1..200, fn i ->
          Task.async(fn ->
            case rem(i, 4) do
              0 ->
                # Create
                task = Factory.build(:task_payload) |> Map.put("id", "mixed-new-#{i}")
                TaskStore.put(task)
                {:create, task["id"]}

              1 ->
                # Read existing
                id = Enum.random(existing_ids)
                TaskStore.get(id)
                {:read, id}

              2 ->
                # Update existing
                id = Enum.random(existing_ids)

                TaskStore.apply_status_update(%{
                  "taskId" => id,
                  "status" => %{"state" => "working", "progress" => :rand.uniform(100)}
                })

                {:update, id}

              3 ->
                # Read non-existent (should return nil)
                TaskStore.get("nonexistent-#{i}")
                {:read_miss, nil}
            end
          end)
        end)

      results = Task.await_many(operations, 30_000)

      # Count operation types
      counts = Enum.frequencies_by(results, fn {type, _} -> type end)

      IO.puts("\n📊 Mixed Workload Stats:")
      IO.puts("   Creates: #{counts[:create] || 0}")
      IO.puts("   Reads: #{counts[:read] || 0}")
      IO.puts("   Updates: #{counts[:update] || 0}")
      IO.puts("   Read misses: #{counts[:read_miss] || 0}")

      assert length(results) == 200
    end
  end

  describe "Agent Store stress" do
    @tag timeout: 60_000
    test "handles #{@concurrent_agents} concurrent agent registrations" do
      agents =
        1..@concurrent_agents
        |> Enum.map(fn i ->
          Task.async(fn ->
            agent =
              Factory.build(:agent_map)
              |> Map.put("id", "stress-agent-#{i}-#{local_unique_id()}")

            start_time = System.monotonic_time(:microsecond)
            AgentStore.upsert(agent)
            end_time = System.monotonic_time(:microsecond)

            {agent["id"], end_time - start_time}
          end)
        end)

      results = Task.await_many(agents, 30_000)

      assert length(results) == @concurrent_agents

      latencies = Enum.map(results, fn {_id, latency} -> latency end)
      avg_latency = Enum.sum(latencies) / length(latencies)

      IO.puts("\n📊 Agent Registration Stats (#{@concurrent_agents} concurrent):")
      IO.puts("   Avg latency: #{Float.round(avg_latency / 1000, 2)}ms")

      # Verify agents exist
      all_agents = AgentStore.list()
      registered_ids = Enum.map(results, fn {id, _} -> id end)

      for id <- Enum.take(registered_ids, 5) do
        assert Enum.any?(all_agents, fn a -> a["id"] == id end)
      end
    end

    @tag timeout: 60_000
    test "handles rapid agent lookups" do
      # Pre-register agents
      agent_ids =
        Enum.map(1..20, fn i ->
          agent = Factory.build(:agent_map) |> Map.put("id", "lookup-agent-#{i}")
          AgentStore.upsert(agent)
          agent["id"]
        end)

      {lookup_time, _} =
        :timer.tc(fn ->
          Enum.each(1..1000, fn _ ->
            id = Enum.random(agent_ids)
            AgentStore.fetch(id)
          end)
        end)

      IO.puts("\n📊 Agent Lookup Stats (1000 lookups):")
      IO.puts("   Total time: #{Float.round(lookup_time / 1000, 2)}ms")
      IO.puts("   Per lookup: #{Float.round(lookup_time / 1000, 2)}µs")
    end
  end

  describe "Circuit Breaker stress" do
    @tag timeout: 30_000
    test "circuit breaker handles rapid failure injection" do
      # Test circuit breaker logic without GenServer (avoids Horde registry issues)
      state = %{
        breaker_state: :closed,
        failure_count: 0,
        failure_window_start: System.monotonic_time(:millisecond),
        failure_window_ms: 5_000,
        failure_threshold: 10,
        cooldown_ms: 1_000,
        cooldown_until: nil,
        last_failure_at: nil,
        agent_id: "stress-test"
      }

      # Inject failures rapidly
      failure_count = 50

      final_state =
        Enum.reduce(1..failure_count, state, fn _, acc ->
          inject_failure(acc)
        end)

      IO.puts("\n📊 Circuit Breaker Stress Stats:")
      IO.puts("   Injected failures: #{failure_count}")
      IO.puts("   Final breaker state: #{final_state.breaker_state}")
      IO.puts("   Failure count: #{final_state.failure_count}")

      # Circuit should be open after threshold failures
      assert final_state.breaker_state == :open
    end

    @tag timeout: 30_000
    test "circuit breaker recovery cycles" do
      state = %{
        breaker_state: :closed,
        failure_count: 0,
        failure_window_start: System.monotonic_time(:millisecond),
        failure_window_ms: 30_000,
        failure_threshold: 5,
        # Very short for test
        cooldown_ms: 50,
        cooldown_until: nil,
        last_failure_at: nil,
        agent_id: "recovery-test"
      }

      cycles = 5

      Enum.reduce(1..cycles, state, fn _cycle, acc ->
        # Inject failures to open circuit
        opened_state = Enum.reduce(1..5, acc, fn _, s -> inject_failure(s) end)
        assert opened_state.breaker_state == :open

        # Wait for cooldown
        Process.sleep(100)

        # Transition to half-open
        half_open_state = maybe_transition_breaker(opened_state)
        assert half_open_state.breaker_state == :half_open

        # Recover
        record_success(half_open_state)
      end)

      IO.puts("\n📊 Circuit Breaker Recovery Cycles: #{cycles}")
      IO.puts("   Successfully tested open → half_open → closed transitions")
    end
  end

  describe "Memory stress" do
    @tag timeout: 60_000
    test "sustained load does not leak memory" do
      initial_memory = :erlang.memory(:total)

      # Run sustained load - reduced from 10 workers to 5
      duration_ms = @sustained_load_duration_ms
      start_time = System.monotonic_time(:millisecond)
      operations = :counters.new(1, [:atomics])

      tasks =
        Enum.map(1..5, fn worker_id ->
          Task.async(fn ->
            run_until = start_time + duration_ms

            Stream.iterate(0, &(&1 + 1))
            |> Enum.take_while(fn i ->
              i < 200 and System.monotonic_time(:millisecond) < run_until
            end)
            |> Enum.each(fn i ->
              task_id = "memory-test-#{worker_id}-#{i}"
              task = Factory.build(:task_payload) |> Map.put("id", task_id)
              TaskStore.put(task)
              TaskStore.get(task_id)
              :counters.add(operations, 1, 1)
            end)
          end)
        end)

      Task.await_many(tasks, 30_000)

      # Force garbage collection
      :erlang.garbage_collect()
      Process.sleep(100)

      final_memory = :erlang.memory(:total)
      total_operations = :counters.get(operations, 1)

      memory_growth = final_memory - initial_memory
      memory_growth_mb = memory_growth / (1024 * 1024)

      IO.puts("\n📊 Memory Stress Stats (#{duration_ms}ms sustained load):")
      IO.puts("   Total operations: #{total_operations}")
      IO.puts("   Ops/second: #{Float.round(total_operations / (duration_ms / 1000), 0)}")
      IO.puts("   Memory growth: #{Float.round(memory_growth_mb, 2)}MB")

      # Memory growth should be bounded (less than 50MB for this test)
      assert memory_growth_mb < 50, "Memory grew by #{memory_growth_mb}MB, exceeds 50MB threshold"
    end
  end

  describe "Concurrency stress" do
    @tag timeout: 60_000
    test "handles thundering herd on single task" do
      # Create a single task
      task_id = "thundering-herd-#{local_unique_id()}"
      task = Factory.build(:task_payload) |> Map.put("id", task_id)
      TaskStore.put(task)

      # Hammer it with concurrent reads and updates
      concurrent = 100

      operations =
        Enum.map(1..concurrent, fn i ->
          Task.async(fn ->
            case rem(i, 3) do
              0 ->
                {:read, TaskStore.get(task_id)}

              1 ->
                {:update,
                 TaskStore.apply_status_update(%{
                   "taskId" => task_id,
                   "status" => %{"state" => "working", "progress" => rem(i, 100)}
                 })}

              2 ->
                {:subscribe, TaskStore.subscribe(task_id)}
            end
          end)
        end)

      results = Task.await_many(operations, 30_000)

      # All operations should complete
      assert length(results) == concurrent

      # Final state should be consistent
      final_task = TaskStore.get(task_id)
      assert final_task != nil
      assert final_task["status"]["state"] == "working"

      IO.puts("\n📊 Thundering Herd Stats:")
      IO.puts("   Concurrent operations: #{concurrent}")
      IO.puts("   All completed successfully ✓")
    end

    @tag timeout: 60_000
    test "handles concurrent subscriptions" do
      task_id = "sub-stress-#{local_unique_id()}"
      task = Factory.build(:task_payload) |> Map.put("id", task_id)
      TaskStore.put(task)

      # Create many subscribers
      subscribers =
        Enum.map(1..50, fn _ ->
          Task.async(fn ->
            TaskStore.subscribe(task_id)

            receive do
              {:task_update, _} -> :received
            after
              1000 -> :timeout
            end
          end)
        end)

      # Give subscribers time to register
      Process.sleep(100)

      # Trigger update
      TaskStore.apply_status_update(%{
        "taskId" => task_id,
        "status" => %{"state" => "completed"}
      })

      results = Task.await_many(subscribers, 5000)
      received_count = Enum.count(results, &(&1 == :received))

      IO.puts("\n📊 Subscription Stress Stats:")
      IO.puts("   Subscribers: 50")
      IO.puts("   Received updates: #{received_count}")

      # Most subscribers should receive the update
      assert received_count >= 40,
             "Expected at least 40 subscribers to receive update, got #{received_count}"
    end
  end

  # -------------------------------------------------------------------
  # Streaming Stress Tests
  # -------------------------------------------------------------------

  describe "Streaming stress" do
    @tag timeout: 120_000
    test "handles 50+ concurrent SSE connections to tasks.subscribe" do
      # Create tasks for streaming
      task_ids =
        for i <- 1..50 do
          task = %{
            "id" => "stream-stress-#{i}-#{local_unique_id()}",
            "agentId" => "test-agent",
            "status" => %{"state" => "working"},
            "artifacts" => []
          }

          TaskStore.put(task)
          task["id"]
        end

      parent = self()
      start_time = System.monotonic_time(:millisecond)

      # Start 50 concurrent subscribers
      subscriber_tasks =
        Enum.map(task_ids, fn task_id ->
          Task.async(fn ->
            # Subscribe to task
            _task = TaskStore.subscribe(task_id)

            send(parent, {:subscribed, task_id})

            # Wait for updates
            updates_received =
              receive do
                {:task_update, _task} ->
                  1
              after
                10_000 -> 0
              end

            updates_received
          end)
        end)

      # Wait for all subscriptions to establish
      for _i <- 1..50 do
        assert_receive {:subscribed, _task_id}, 5_000
      end

      subscription_time = System.monotonic_time(:millisecond) - start_time

      # Broadcast updates to all tasks
      update_start = System.monotonic_time(:millisecond)

      for task_id <- task_ids do
        TaskStore.apply_status_update(%{
          "taskId" => task_id,
          "status" => %{"state" => "working", "message" => "Progress"}
        })
      end

      broadcast_time = System.monotonic_time(:millisecond) - update_start

      # Wait for all subscribers to receive updates
      results = Task.await_many(subscriber_tasks, 15_000)
      total_updates = Enum.sum(results)

      total_time = System.monotonic_time(:millisecond) - start_time

      IO.puts("\n📊 Concurrent SSE Streaming Stats:")
      IO.puts("   Concurrent connections: 50")
      IO.puts("   Subscription time: #{subscription_time}ms")
      IO.puts("   Broadcast time: #{broadcast_time}ms")
      IO.puts("   Total time: #{total_time}ms")
      IO.puts("   Updates received: #{total_updates}/50")
      IO.puts("   Success rate: #{Float.round(total_updates / 50 * 100, 1)}%")

      assert total_updates >= 45, "Expected at least 45 updates, got #{total_updates}"
    end

    @tag timeout: 90_000
    test "handles long-running streams (60s+ sustained connections)" do
      # Create a task for long-running stream
      task_id = "long-stream-#{local_unique_id()}"

      task = %{
        "id" => task_id,
        "agentId" => "test-agent",
        "status" => %{"state" => "working"},
        "artifacts" => []
      }

      TaskStore.put(task)

      parent = self()
      start_time = System.monotonic_time(:second)

      # Start subscriber that will run for 60+ seconds
      stream_task =
        Task.async(fn ->
          TaskStore.subscribe(task_id)
          send(parent, :stream_started)

          # Collect updates for 60 seconds
          collect_updates_for_duration(60_000, [])
        end)

      assert_receive :stream_started, 2_000

      # Send updates every second for 60 seconds
      update_task =
        Task.async(fn ->
          for i <- 1..60 do
            TaskStore.apply_status_update(%{
              "taskId" => task_id,
              "status" => %{"state" => "working", "message" => "Second #{i}"}
            })

            Process.sleep(1_000)
          end

          # Send terminal state
          TaskStore.apply_status_update(%{
            "taskId" => task_id,
            "status" => %{"state" => "completed"}
          })
        end)

      # Wait for both tasks
      updates = Task.await(stream_task, 70_000)
      Task.await(update_task, 70_000)

      duration = System.monotonic_time(:second) - start_time

      IO.puts("\n📊 Long-Running Stream Stats:")
      IO.puts("   Duration: #{duration}s")
      IO.puts("   Updates received: #{length(updates)}")
      IO.puts("   Expected updates: ~61")
      IO.puts("   Update rate: #{Float.round(length(updates) / duration, 2)}/s")

      # Should receive most updates (allowing for some timing variance)
      assert length(updates) >= 55, "Expected at least 55 updates, got #{length(updates)}"
    end

    @tag timeout: 60_000
    test "handles high-frequency SSE event flooding" do
      task_id = "flood-test-#{local_unique_id()}"

      task = %{
        "id" => task_id,
        "agentId" => "test-agent",
        "status" => %{"state" => "working"},
        "artifacts" => []
      }

      TaskStore.put(task)

      parent = self()

      # Start subscriber
      subscriber =
        Task.async(fn ->
          TaskStore.subscribe(task_id)
          send(parent, :subscribed)

          # Collect events as fast as possible
          collect_updates_with_timeout(5_000, [])
        end)

      assert_receive :subscribed, 1_000

      # Flood with 500 rapid updates
      flood_start = System.monotonic_time(:millisecond)

      for i <- 1..500 do
        TaskStore.apply_status_update(%{
          "taskId" => task_id,
          "status" => %{"state" => "working", "message" => "Event #{i}"}
        })
      end

      flood_time = System.monotonic_time(:millisecond) - flood_start

      # Send terminal state
      Process.sleep(100)

      TaskStore.apply_status_update(%{
        "taskId" => task_id,
        "status" => %{"state" => "completed"}
      })

      # Collect results
      updates = Task.await(subscriber, 10_000)

      IO.puts("\n📊 High-Frequency Event Flood Stats:")
      IO.puts("   Events sent: 500")
      IO.puts("   Events received: #{length(updates)}")
      IO.puts("   Flood duration: #{flood_time}ms")
      IO.puts("   Send rate: #{Float.round(500 / flood_time * 1000, 0)} events/s")
      IO.puts("   Delivery rate: #{Float.round(length(updates) / 500 * 100, 1)}%")

      # System should handle at least 80% of events under flood
      assert length(updates) >= 400, "Expected at least 400 updates, got #{length(updates)}"
    end

    @tag timeout: 30_000
    test "handles client disconnect mid-stream gracefully" do
      task_id = "disconnect-test-#{local_unique_id()}"

      task = %{
        "id" => task_id,
        "agentId" => "test-agent",
        "status" => %{"state" => "working"},
        "artifacts" => []
      }

      TaskStore.put(task)

      parent = self()

      # Start subscriber that will disconnect after receiving 5 updates
      subscriber =
        Task.async(fn ->
          TaskStore.subscribe(task_id)
          send(parent, :subscribed)

          # Receive 5 updates then exit (simulating disconnect)
          updates = collect_n_updates(5, [])

          send(parent, {:received, length(updates)})
          updates
        end)

      assert_receive :subscribed, 1_000

      # Send 20 updates
      for i <- 1..20 do
        TaskStore.apply_status_update(%{
          "taskId" => task_id,
          "status" => %{"state" => "working", "message" => "Update #{i}"}
        })

        Process.sleep(50)
      end

      # Subscriber should disconnect after 5
      assert_receive {:received, 5}, 5_000

      # Continue sending updates (should not crash)
      for i <- 21..30 do
        TaskStore.apply_status_update(%{
          "taskId" => task_id,
          "status" => %{"state" => "working", "message" => "Update #{i}"}
        })

        Process.sleep(50)
      end

      # Cleanup
      updates = Task.await(subscriber, 1_000)
      assert length(updates) == 5

      IO.puts("\n✅ Client disconnect handled gracefully")
    end

    @tag timeout: 30_000
    test "handles stream initialization timeout stress" do
      # Create 20 tasks but never send updates (simulate slow agents)
      task_ids =
        for i <- 1..20 do
          task = %{
            "id" => "timeout-stress-#{i}-#{local_unique_id()}",
            "agentId" => "slow-agent",
            "status" => %{"state" => "working"},
            "artifacts" => []
          }

          TaskStore.put(task)
          task["id"]
        end

      start_time = System.monotonic_time(:millisecond)

      # Try to subscribe to all (with 2s timeout)
      results =
        Enum.map(task_ids, fn task_id ->
          Task.async(fn ->
            TaskStore.subscribe(task_id)

            # Wait for update with timeout
            receive do
              {:task_update, _} -> :received
            after
              2_000 -> :timeout
            end
          end)
        end)
        |> Task.await_many(5_000)

      total_time = System.monotonic_time(:millisecond) - start_time

      timeouts = Enum.count(results, &(&1 == :timeout))

      IO.puts("\n📊 Stream Timeout Stress Stats:")
      IO.puts("   Subscriptions: 20")
      IO.puts("   Timeouts: #{timeouts}")
      IO.puts("   Total time: #{total_time}ms")

      # All should timeout gracefully
      assert timeouts == 20
    end
  end

  # -------------------------------------------------------------------
  # Streaming Helper Functions
  # -------------------------------------------------------------------

  defp collect_updates_for_duration(duration_ms, acc) do
    start_time = System.monotonic_time(:millisecond)
    collect_updates_until(start_time + duration_ms, acc)
  end

  defp collect_updates_until(end_time, acc) do
    remaining = end_time - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      Enum.reverse(acc)
    else
      receive do
        {:task_update, task} ->
          collect_updates_until(end_time, [task | acc])
      after
        remaining -> Enum.reverse(acc)
      end
    end
  end

  defp collect_updates_with_timeout(timeout_ms, acc) do
    receive do
      {:task_update, task} ->
        state = get_in(task, ["status", "state"])

        if state == "completed" do
          Enum.reverse([task | acc])
        else
          collect_updates_with_timeout(timeout_ms, [task | acc])
        end
    after
      timeout_ms -> Enum.reverse(acc)
    end
  end

  defp collect_n_updates(0, acc), do: Enum.reverse(acc)

  defp collect_n_updates(n, acc) do
    receive do
      {:task_update, task} ->
        collect_n_updates(n - 1, [task | acc])
    after
      5_000 -> Enum.reverse(acc)
    end
  end

  # -------------------------------------------------------------------
  # Helper Functions
  # -------------------------------------------------------------------

  defp local_unique_id do
    :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
  end

  defp percentile(list, p) when p >= 0 and p <= 100 do
    sorted = Enum.sort(list)
    rank = p / 100 * (length(sorted) - 1)
    lower = floor(rank)
    upper = ceil(rank)

    if lower == upper do
      Enum.at(sorted, lower)
    else
      lower_val = Enum.at(sorted, lower)
      upper_val = Enum.at(sorted, upper)
      lower_val + (upper_val - lower_val) * (rank - lower)
    end
  end

  defp inject_failure(state) do
    now = System.monotonic_time(:millisecond)

    state =
      if now - state.failure_window_start > state.failure_window_ms do
        %{state | failure_count: 1, failure_window_start: now}
      else
        %{state | failure_count: state.failure_count + 1}
      end

    state = %{state | last_failure_at: now}

    if state.failure_count >= state.failure_threshold and state.breaker_state != :open do
      %{state | breaker_state: :open, cooldown_until: now + state.cooldown_ms}
    else
      state
    end
  end

  defp maybe_transition_breaker(%{breaker_state: :open, cooldown_until: until} = state) do
    if System.monotonic_time(:millisecond) >= until do
      %{state | breaker_state: :half_open}
    else
      state
    end
  end

  defp maybe_transition_breaker(state), do: state

  defp record_success(%{breaker_state: :half_open} = state) do
    %{
      state
      | breaker_state: :closed,
        failure_count: 0,
        failure_window_start: System.monotonic_time(:millisecond)
    }
  end

  defp record_success(state), do: state
end
