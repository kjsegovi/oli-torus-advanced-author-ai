defmodule Oli.GoogleSlides.ImportRuns.AnalysisWorkflow do
  @moduledoc """
  Contract used by `AnalysisWorker`.

  Implementations receive an import-run id and return one of:

    * `{:ok, :awaiting_answers, attrs}`
    * `{:ok, :ready_for_review, attrs}`
    * `{:error, reason}`

  The worker, rather than the implementation, persists the lifecycle
  transition. This keeps AI analysis unable to mutate live course content.
  """

  @callback perform(Ecto.UUID.t()) ::
              {:ok, :awaiting_answers | :ready_for_review, map()}
              | {:error, term()}
end

defmodule Oli.GoogleSlides.ImportRuns.GenerationWorkflow do
  @moduledoc """
  Contract used by `GenerationWorker`.

  A successful implementation returns `{:ok, attrs}`. The attributes must
  include `result_revision_id`; they may also include `result`, `warnings`,
  `validation_results`, and `model_usage`.
  """

  @callback perform(Ecto.UUID.t()) :: {:ok, map()} | {:error, term()}
end
