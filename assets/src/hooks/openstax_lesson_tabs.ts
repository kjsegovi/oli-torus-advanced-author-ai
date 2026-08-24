import type { Hook } from 'phoenix_live_view/assets/js/types/view_hook';

type LessonTabsHook = Hook & {
  clickHandler?: (event: MouseEvent) => void;
  keyHandler?: (event: KeyboardEvent) => void;
  focusQualityId?: string;
};

function tabs(root: HTMLElement): HTMLElement[] {
  return Array.from(root.querySelectorAll<HTMLElement>('[data-lesson-tab]'));
}

function selectedTab(root: HTMLElement): HTMLElement | null {
  return root.querySelector<HTMLElement>('[data-lesson-tab][data-selected="true"]');
}

function scrollSelected(root: HTMLElement) {
  selectedTab(root)?.scrollIntoView({ behavior: 'smooth', block: 'nearest', inline: 'center' });
}

function focusQuality(id?: string) {
  if (!id) return;

  const quality = document.getElementById(`openstax-v7-quality-${id}`);
  if (!quality) return;

  quality.setAttribute('tabindex', '-1');
  quality.focus({ preventScroll: true });
  quality.scrollIntoView({ behavior: 'smooth', block: 'start' });
}

export const OpenStaxLessonTabs: LessonTabsHook = {
  mounted() {
    const root = this.el as HTMLElement;

    this.clickHandler = (event: MouseEvent) => {
      const target = event.target as HTMLElement;
      const scrollButton = target.closest<HTMLElement>('[data-tab-scroll]');
      const strip = root.querySelector<HTMLElement>('[data-tab-strip]');

      if (scrollButton && strip) {
        const direction = scrollButton.dataset.tabScroll === 'previous' ? -1 : 1;
        strip.scrollBy({
          left: direction * Math.max(strip.clientWidth * 0.75, 240),
          behavior: 'smooth',
        });
      }

      const qualityLink = target.closest<HTMLElement>('[data-openstax-focus-quality]');
      if (qualityLink) this.focusQualityId = qualityLink.dataset.openstaxFocusQuality;
    };

    this.keyHandler = (event: KeyboardEvent) => {
      const target = (event.target as HTMLElement).closest<HTMLElement>('[data-lesson-tab]');
      if (!target) return;

      const items = tabs(root);
      const index = items.indexOf(target);
      let nextIndex: number | null = null;

      switch (event.key) {
        case 'ArrowLeft':
          nextIndex = index > 0 ? index - 1 : items.length - 1;
          break;
        case 'ArrowRight':
          nextIndex = index < items.length - 1 ? index + 1 : 0;
          break;
        case 'Home':
          nextIndex = 0;
          break;
        case 'End':
          nextIndex = items.length - 1;
          break;
        case ' ':
        case 'Spacebar':
          event.preventDefault();
          target.click();
          return;
        case 'Enter':
          return;
        default:
          return;
      }

      event.preventDefault();
      items[nextIndex]?.focus();
    };

    root.addEventListener('click', this.clickHandler);
    root.addEventListener('keydown', this.keyHandler);
    requestAnimationFrame(() => scrollSelected(root));
  },

  updated() {
    const root = this.el as HTMLElement;
    requestAnimationFrame(() => {
      scrollSelected(root);
      focusQuality(this.focusQualityId);
      this.focusQualityId = undefined;
    });
  },

  destroyed() {
    const root = this.el as HTMLElement;
    if (this.clickHandler) root.removeEventListener('click', this.clickHandler);
    if (this.keyHandler) root.removeEventListener('keydown', this.keyHandler);
  },
};
