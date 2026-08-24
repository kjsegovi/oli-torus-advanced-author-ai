defmodule Oli.OpenStax.CourseImport.AIPricingTest do
  use ExUnit.Case, async: true

  alias Oli.OpenStax.CourseImport.AIPricing

  test "prices input, cached input, output, and service tiers with versioned rates" do
    usage = %{input_tokens: 1_000, cached_input_tokens: 200, output_tokens: 100}

    assert AIPricing.estimate_microdollars("gpt-5.6-terra", "standard", usage) == 2_840
    assert AIPricing.estimate_microdollars("gpt-5.6-terra", "flex", usage) == 1_420
    assert AIPricing.pricing_version() == "openai-2026-08-24"
  end

  test "applies cache-write and long-context adjustments" do
    assert AIPricing.estimate_microdollars("gpt-5.6-terra", "standard", %{
             input_tokens: 300_000,
             cache_write_tokens: 10_000,
             output_tokens: 1_000
           }) == 1_268_000
  end

  test "reserves against the configured maximum output rather than an average" do
    assert AIPricing.estimate_max_microdollars("gpt-5.6-terra", "flex", %{
             input_tokens: 1_000,
             max_output_tokens: 12_000
           }) == 73_000
  end
end
