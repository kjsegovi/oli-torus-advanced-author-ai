import { OpenStaxLessonTabs } from 'hooks/openstax_lesson_tabs';

describe('OpenStaxLessonTabs', () => {
  let scrollIntoView: jest.Mock;
  let scrollBy: jest.Mock;

  beforeEach(() => {
    scrollIntoView = jest.fn();
    scrollBy = jest.fn();

    Object.defineProperty(HTMLElement.prototype, 'scrollIntoView', {
      configurable: true,
      value: scrollIntoView,
    });

    Object.defineProperty(HTMLElement.prototype, 'scrollBy', {
      configurable: true,
      value: scrollBy,
    });

    jest.spyOn(window, 'requestAnimationFrame').mockImplementation((callback) => {
      callback(0);
      return 1;
    });

    document.body.innerHTML = `
      <div id="lesson-tabs">
        <button data-tab-scroll="previous">Previous</button>
        <div data-tab-strip role="tablist">
          <a id="lesson-1" data-lesson-tab data-selected="true" href="#one">One</a>
          <a id="lesson-2" data-lesson-tab data-selected="false" href="#two">Two</a>
          <a id="lesson-3" data-lesson-tab data-selected="false" href="#three">Three</a>
        </div>
        <button data-tab-scroll="next">Next</button>
        <button data-openstax-focus-quality="lesson-2">Review details</button>
      </div>
      <section id="openstax-v7-quality-lesson-2">Quality findings</section>
    `;
  });

  afterEach(() => {
    document.body.innerHTML = '';
    jest.restoreAllMocks();
  });

  test('supports tab keyboard navigation, overflow controls, and finding focus restoration', () => {
    const root = document.getElementById('lesson-tabs') as HTMLElement;
    const hook = { el: root };
    const first = document.getElementById('lesson-1') as HTMLElement;
    const second = document.getElementById('lesson-2') as HTMLElement;
    const third = document.getElementById('lesson-3') as HTMLElement;

    OpenStaxLessonTabs.mounted!.call(hook as any);

    expect(scrollIntoView).toHaveBeenCalledWith({
      behavior: 'smooth',
      block: 'nearest',
      inline: 'center',
    });

    first.focus();
    first.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true }));
    expect(second).toHaveFocus();

    second.dispatchEvent(new KeyboardEvent('keydown', { key: 'End', bubbles: true }));
    expect(third).toHaveFocus();

    third.dispatchEvent(new KeyboardEvent('keydown', { key: 'Home', bubbles: true }));
    expect(first).toHaveFocus();

    root
      .querySelector<HTMLElement>('[data-tab-scroll="next"]')
      ?.dispatchEvent(new MouseEvent('click', { bubbles: true }));
    expect(scrollBy).toHaveBeenCalledWith({ left: 240, behavior: 'smooth' });

    root
      .querySelector<HTMLElement>('[data-openstax-focus-quality]')
      ?.dispatchEvent(new MouseEvent('click', { bubbles: true }));
    OpenStaxLessonTabs.updated!.call(hook as any);

    expect(document.activeElement).toBe(document.getElementById('openstax-v7-quality-lesson-2'));

    OpenStaxLessonTabs.destroyed!.call(hook as any);
  });
});
