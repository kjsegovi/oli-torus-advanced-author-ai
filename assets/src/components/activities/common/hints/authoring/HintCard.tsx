import React from 'react';
import { Hint, RichText } from 'components/activities/types';
import { SlateOrMarkdownEditor } from 'components/editing/SlateOrMarkdownEditor';
import { Card } from 'components/misc/Card';
import { TextDirection } from 'data/content/model/elements/types';
import { ID } from 'data/content/model/other';
import { DEFAULT_EDITOR, EditorType } from 'data/content/resource';

export const HintCard: React.FC<{
  title: JSX.Element;
  placeholder: string;
  hint?: Hint;
  createOne: (attrs: {
    content?: RichText;
    editor?: EditorType;
    textDirection?: TextDirection;
  }) => void;
  updateOne: (id: ID, content: RichText) => void;
  updateOneEditor: (id: ID, editor: EditorType) => void;
  updateOneTextDirection: (id: ID, textDirection: TextDirection) => void;
  projectSlug: string;
}> = ({
  title,
  placeholder,
  hint,
  createOne,
  updateOne,
  updateOneEditor,
  updateOneTextDirection,
  projectSlug,
}) => {
  return (
    <Card.Card>
      <Card.Title>{title}</Card.Title>
      <Card.Content>
        <SlateOrMarkdownEditor
          placeholder={placeholder}
          content={hint?.content || []}
          onEdit={(content) => (hint ? updateOne(hint.id, content) : createOne({ content }))}
          editMode={true}
          editorType={hint?.editor || DEFAULT_EDITOR}
          onEditorTypeChange={(editor) =>
            hint ? updateOneEditor(hint.id, editor) : createOne({ editor })
          }
          allowBlockElements={true}
          projectSlug={projectSlug}
          textDirection={hint?.textDirection}
          onChangeTextDirection={(textDirection) =>
            hint ? updateOneTextDirection(hint.id, textDirection) : createOne({ textDirection })
          }
        />
      </Card.Content>
    </Card.Card>
  );
};
