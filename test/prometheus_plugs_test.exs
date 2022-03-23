defmodule PrometheusPlugsTest do
  use ExUnit.Case
  use Plug.Test
  ## doctest Plug.PrometheusCollector
  ## doctest Plug.PrometheusExporter

  require Prometheus.Registry
  require Prometheus.Format.Text
  require Prometheus.Format.Protobuf

  setup do
    Prometheus.Registry.clear(:default)
    Prometheus.Registry.clear(:qwe)

    Prometheus.TestPlugPipelineInstrumenter.setup()
    Prometheus.TestPlugPipelineInstrumenterCustomConfig.setup()
    Prometheus.TestPlugExporter.setup()
    Prometheus.TestPlugExporterCustomConfig.setup()
    Prometheus.VeryImportantPlugCounter.setup()
    Prometheus.VeryImportantPlugHistogram.setup()
    Prometheus.VeryImportantPlugInstrumenter.setup()

    :ok
  end

  use Prometheus.Metric

  defp call(conn) do
    Prometheus.TestPlugStack.call(conn, Prometheus.TestPlugStack.init([]))
  end

  test "the truth" do
    assert 1 + 1 == 2
  end

  test "Plug Pipeline Instrumenter tests" do
    conn = call(conn(:get, "/"))
    assert conn.resp_body == "Hello World!"

    assert 1 ==
             Counter.value(
               name: :http_requests_total,
               registry: :default,
               labels: ['success', "GET", "www.example.com", :http]
             )

    assert 1 ==
             Counter.value(
               name: :http_requests_total,
               registry: :qwe,
               labels: ["GET", 12]
             )

    assert {buckets, sum} =
             Histogram.value(
               name: :http_request_duration_microseconds,
               registry: :default,
               labels: ['success', "GET", "www.example.com", :http]
             )

    assert sum > 1_000_000 and sum < 1_200_000
    assert 20 = length(buckets)
    assert 1 = Enum.reduce(buckets, fn x, acc -> x + acc end)

    assert {buckets, sum} =
             Histogram.value(
               name: :http_request_duration_seconds,
               registry: :qwe,
               labels: ["GET", 12]
             )

    assert sum > 1.0e-10 and sum < 1.0e-8
    assert 3 = length(buckets)
    assert 1 = Enum.reduce(buckets, fn x, acc -> x + acc end)
  end

  test "Plug instrumenter tests" do
    ## two histograms by Pipeline instrumenters and two by Plug instrumenters
    ## 4 histogram mfs + 1 vip_histogram initialized to zeros because no metrics
    ## TODO: remove
    assert 5 = length(:ets.tab2list(:prometheus_histogram_table))
    ## two counters by Pipeline instrumenters and two by Plug instrumenters
    assert 5 = length(:ets.tab2list(:prometheus_counter_table))

    conn = call(conn(:get, "/"))
    assert conn |> get_resp_header("x-request-id")
    assert conn.resp_body == "Hello World!"

    assert 1 ==
             Counter.value(
               name: :vip_only_counter,
               labels: [:other]
             )

    assert 1 ==
             Counter.value(
               name: :vip_counter,
               labels: []
             )

    assert {buckets, sum} =
             Histogram.value(
               name: :vip_only_histogram_microseconds,
               registry: :qwe,
               labels: [:other]
             )

    assert sum > 0
    assert 3 = length(buckets)
    assert 1 = Enum.reduce(buckets, fn x, acc -> x + acc end)

    assert {buckets, sum} = Histogram.value(name: :vip_histogram)
    assert sum > 0
    assert 20 = length(buckets)
    assert 1 = Enum.reduce(buckets, fn x, acc -> x + acc end)

    conn = call(conn(:get, "/qwe/qwe"))
    assert conn.resp_body == "Hello World!"

    assert 1 ==
             Counter.value(
               name: :vip_only_counter,
               labels: [:qwe]
             )

    assert 2 == Counter.value(name: :vip_counter)

    assert {buckets, sum} =
             Histogram.value(
               name: :vip_only_histogram_microseconds,
               registry: :qwe,
               labels: [:qwe]
             )

    assert sum > 1_000_000 and sum < 1_200_000
    assert 3 = length(buckets)
    assert 1 = Enum.reduce(buckets, fn x, acc -> x + acc end)

    assert {buckets, sum} = Histogram.value(name: :vip_histogram)

    assert sum > 1.0 and sum < 1.2
    assert 20 = length(buckets)
    assert 2 = Enum.reduce(buckets, fn x, acc -> x + acc end)
  end

  test "Plug Exporter tests" do
    conn = call(conn(:get, "/"))
    assert conn.resp_body == "Hello World!"

    ## no accept header, exporter should fallback to text
    call(conn(:get, "/metrics"))
    conn = call(conn(:get, "/metrics"))

    assert [Prometheus.Format.Text.content_type()] == conn |> get_resp_header("content-type")

    assert {_, _} =
             :binary.match(
               conn.resp_body,
               "http_request_duration_microseconds_bucket{status_class=\"success\",method=\"GET\",host=\"www.example.com\",scheme=\"http\",le=\"+Inf\"} 1"
             )

    assert {_, _} =
             :binary.match(
               conn.resp_body,
               "telemetry_scrape_size_bytes_count{registry=\"default\",content_type=\"text/plain; version=0.0.4\"} 1"
             )

    assert {_, _} =
             :binary.match(
               conn.resp_body,
               "telemetry_scrape_duration_seconds_count{registry=\"default\",content_type=\"text/plain; version=0.0.4\"} 1"
             )

    ## Prometheus server accept header
    conn =
      conn(:get, "/metrics")
      |> put_req_header(
        "accept",
        "application/vnd.google.protobuf;" <>
          "proto=io.prometheus.client.MetricFamily;encoding=delimited;q=0.7," <>
          "text/plain;version=0.0.4;q=0.3," <>
          "application/json;schema=\"prometheus/telemetry\";version=0.0.2;q=0.2," <> "*/*;q=0.1"
      )
      |> call

    assert [Prometheus.Format.Protobuf.content_type()] == conn |> get_resp_header("content-type")

    ## Chrome accept header
    conn =
      conn(:get, "/metrics")
      |> put_req_header(
        "accept",
        "application/xml,application/xhtml+xml," <>
          "text/html;q=0.9,text/plain;q=0.8,image/png,image/*;q=0.9,*/*;q=0.5"
      )
      |> call

    assert [Prometheus.Format.Text.content_type()] == conn |> get_resp_header("content-type")

    conn = call(conn(:get, "/metrics_qwe"))
    assert conn.status == 401

    auth_header_content = "Basic " <> Base.encode64("qwe:qwe")

    conn =
      conn(:get, "/metrics_qwe")
      |> put_req_header("authorization", auth_header_content)
      |> call

    assert [Prometheus.Format.Protobuf.content_type()] == conn |> get_resp_header("content-type")
    ## TODO: decode and check protobuf resp body
    assert conn.resp_body > 0
  end
end
