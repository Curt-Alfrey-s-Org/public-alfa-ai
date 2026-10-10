import { useId, useLayoutEffect, useRef, useState, type ReactNode } from "react";

type ExpandableClipProps = {
  children: ReactNode;
  /** Tailwind max-height while collapsed. */
  collapsedClassName: string;
  className?: string;
  /** Shown on the disclosure button (WAI-ARIA APG Disclosure). */
  expandLabel?: string;
  collapseLabel?: string;
};

/**
 * Collapse tall content behind Expand/Collapse.
 * Collapsed uses overflow:hidden (not overflow:auto) so the box does not
 * steal wheel events -- CSS Overflow Module:
 * https://www.w3.org/TR/css-overflow-3/#overflow-properties
 * Disclosure: https://www.w3.org/WAI/ARIA/apg/patterns/disclosure/
 * ResizeObserver: https://developer.mozilla.org/en-US/docs/Web/API/ResizeObserver
 */
export default function ExpandableClip({
  children,
  collapsedClassName,
  className = "",
  expandLabel = "Expand",
  collapseLabel = "Collapse",
}: ExpandableClipProps) {
  const panelId = useId();
  const bodyRef = useRef<HTMLDivElement>(null);
  const [expanded, setExpanded] = useState(false);
  const [overflows, setOverflows] = useState(false);

  useLayoutEffect(() => {
    const el = bodyRef.current;
    if (!el) return;

    const measure = () => {
      if (expanded) {
        setOverflows(true);
        return;
      }
      setOverflows(el.scrollHeight > el.clientHeight + 1);
    };

    measure();
    if (typeof ResizeObserver === "undefined") {
      return;
    }
    const observer = new ResizeObserver(measure);
    observer.observe(el);
    return () => observer.disconnect();
  }, [expanded, children]);

  const showToggle = overflows || expanded;

  return (
    <div className="min-w-0">
      <div
        id={panelId}
        ref={bodyRef}
        className={`${className} ${expanded ? "" : `${collapsedClassName} overflow-hidden`}`}
      >
        {children}
      </div>
      {showToggle ? (
        <button
          type="button"
          className="mt-1.5 text-[11px] font-medium text-sky-400 hover:text-sky-300"
          aria-expanded={expanded}
          aria-controls={panelId}
          onClick={() => setExpanded((current) => !current)}
        >
          {expanded ? collapseLabel : expandLabel}
        </button>
      ) : null}
    </div>
  );
}
