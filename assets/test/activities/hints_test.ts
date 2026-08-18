import { ScoringStrategy, makeHint } from 'components/activities/types';
import { Hints } from 'data/activities/model/hints';
import { dispatch } from 'utils/test_utils';

describe('authoring hints', () => {
  const model = {
    authoring: {
      parts: [
        {
          id: '1',
          hints: [makeHint(''), makeHint(''), makeHint('')],
          responses: [],
          scoringStrategy: {} as ScoringStrategy,
        },
      ],
    },
  };

  it('can add a cognitive hint before the end of the array', () => {
    expect(
      Hints.byPart(dispatch(model, Hints.addCognitiveHint(makeHint(''), '1')), '1').length,
    ).toBeGreaterThan(Hints.byPart(model, '1').length);
  });

  it('can edit a hint', () => {
    const newHintContent = makeHint('new content').content;
    const firstHint = Hints.byPart(model, '1')[0];
    expect(
      Hints.byPart(dispatch(model, Hints.setContent(firstHint.id, newHintContent)), '1')[0],
    ).toHaveProperty('content', newHintContent);
  });

  it('can remove a hint', () => {
    const firstHint = Hints.byPart(model, '1')[0];
    expect(Hints.byPart(dispatch(model, Hints.removeOne(firstHint.id, '1')), '1')).toHaveLength(2);
  });

  it('treats an absent hint list as empty', () => {
    const missingHints = {
      authoring: {
        parts: [{ id: '1', responses: [], scoringStrategy: {} as ScoringStrategy }],
      },
    };

    expect(Hints.byPart(missingHints as any, '1')).toEqual([]);
    expect(Hints.getDeerInHeadlightsHint(missingHints as any, '1')).toBeUndefined();
    expect(Hints.getBottomOutHint(missingHints as any, '1')).toBeUndefined();
  });

  it('creates a missing required hint on first edit and reuses it for later edits', () => {
    const missingHints = {
      authoring: {
        parts: [
          {
            id: '1',
            hints: [],
            responses: [],
            scoringStrategy: {} as ScoringStrategy,
          },
        ],
      },
    };
    const draft = makeHint('');
    const firstContent = makeHint('Explain the answer.').content;
    const secondContent = makeHint('Explain the answer with evidence.').content;

    const created = dispatch(
      missingHints as any,
      Hints.upsertRequiredHint(draft, '1', 'end', { content: firstContent }),
    );
    const updated = dispatch(
      created,
      Hints.upsertRequiredHint(draft, '1', 'end', { content: secondContent }),
    );

    expect(Hints.byPart(updated, '1')).toHaveLength(1);
    expect(Hints.byPart(updated, '1')[0]).toMatchObject({
      id: draft.id,
      content: secondContent,
    });
  });
});
