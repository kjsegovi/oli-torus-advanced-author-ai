defmodule Oli.GoogleSlides.AI.CatalogTest do
  use ExUnit.Case, async: true

  alias Oli.GoogleSlides.AI.Catalog

  test "normalizes reviewed component aliases" do
    assert Catalog.version() == 1
    assert {:ok, "multiple_choice"} = Catalog.normalize_component_key("janus-mcq")
    assert {:ok, %{"partType" => "janus-input-text"}} = Catalog.component(:text_input)
    assert Catalog.automatically_evaluated?("dropdown")
    refute Catalog.supported_component?("invented-lab-widget")
  end

  test "exposes versioned product profiles without accepting arbitrary stylesheets" do
    assert {:ok, profile} = Catalog.style_profile("habworlds")
    assert profile["key"] == "habworlds-lesson"

    assert "https://etx-css-assets.s3.us-west-2.amazonaws.com/habworlds/style.css" in profile[
             "approvedStylesheets"
           ]

    assert Catalog.approved_stylesheet?(
             "https://etx-css-assets.s3.us-west-2.amazonaws.com/biobeyond/style_biobeyond.css"
           )

    refute Catalog.approved_stylesheet?("https://example.com/unreviewed.css")
    assert {:error, :unsupported_style_profile} = Catalog.style_profile("unreviewed-product")
  end

  test "marks unresolved catalog guidance as requiring confirmation instead of guessing a URL" do
    assert {:ok, assessment} = Catalog.style_profile("habworlds-assessment")
    assert assessment["selectionRequiresConfirmation"]

    assert assessment["approvedStylesheets"] == [
             "/css/delivery_adaptive_themes_default_light.css"
           ]
  end
end
