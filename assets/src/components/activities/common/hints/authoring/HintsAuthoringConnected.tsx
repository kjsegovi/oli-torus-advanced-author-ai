import React, { useMemo } from 'react';
import { useAuthoringElementContext } from 'components/activities/AuthoringElementProvider';
import { HintsAuthoring } from 'components/activities/common/hints/authoring/HintsAuthoring';
import { HasParts, makeHint } from 'components/activities/types';
import { Hints as HintUtils } from 'data/activities/model/hints';

interface Props {
  partId: string;
}
export const Hints: React.FC<Props> = (props) => {
  const { dispatch, model } = useAuthoringElementContext<HasParts>();
  const hints = HintUtils.byPart(model, props.partId);
  const deerInHeadlightsHint = hints[0];
  const bottomOutHint = hints.length > 1 ? hints[hints.length - 1] : undefined;
  const cognitiveHints = hints.length > 1 ? hints.slice(1, hints.length - 1) : [];
  const deerDraft = useMemo(() => makeHint(''), [props.partId]);
  const bottomOutDraft = useMemo(() => makeHint(''), [props.partId]);

  return (
    <HintsAuthoring
      addOne={() => dispatch(HintUtils.addCognitiveHint(makeHint(''), props.partId))}
      updateOne={(id, content) => dispatch(HintUtils.setContent(id, content))}
      updateOneEditor={(id, editor) => dispatch(HintUtils.setEditor(id, editor))}
      updateOneTextDirection={(id, textDirection) =>
        dispatch(HintUtils.setTextDirection(id, textDirection))
      }
      removeOne={(id) => dispatch(HintUtils.removeOne(id, props.partId))}
      createDeerInHeadlightsHint={(attrs) =>
        dispatch(HintUtils.upsertRequiredHint(deerDraft, props.partId, 'start', attrs))
      }
      createBottomOutHint={(attrs) =>
        dispatch(HintUtils.upsertRequiredHint(bottomOutDraft, props.partId, 'end', attrs))
      }
      deerInHeadlightsHint={deerInHeadlightsHint}
      cognitiveHints={cognitiveHints}
      bottomOutHint={bottomOutHint}
    />
  );
};
