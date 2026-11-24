import AppKit

/// WebKit shows a `<select>`'s list as a native menu and `title` hovers as
/// native tooltips. Both open on the real screen where the hidden window sits,
/// so they float over Rex instead of landing in the pane's image. This draws
/// select lists in the page instead (so they're captured like any other
/// content) and keeps native menus from staying open.
enum Popups {
    /// Opens an in-page list for single-choice selects on click or on the
    /// keys that would open the native menu (space, enter, arrows).
    static let script = """
    (() => {
      if (window.__rexSelect) return;
      window.__rexSelect = true;
      let open = null;
      const isPopup = s => s instanceof HTMLSelectElement && !s.multiple && (s.size || 0) <= 1 && !s.disabled;

      const close = () => {
        if (!open) return;
        open.host.remove();
        removeEventListener('scroll', onScroll, true);
        removeEventListener('resize', close, true);
        removeEventListener('blur', close, true);
        open = null;
      };
      const onScroll = e => { if (open && !open.host.contains(e.target) && e.target !== open.list) close(); };

      const choose = i => {
        const s = open.select;
        close();
        s.focus({preventScroll: true});
        if (s.selectedIndex === i) return;
        s.selectedIndex = i;
        s.dispatchEvent(new Event('input', {bubbles: true, composed: true}));
        s.dispatchEvent(new Event('change', {bubbles: true}));
      };

      const highlight = i => {
        if (!open) return;
        open.items.forEach(it => it.el.classList.toggle('hi', it.index === i));
        open.hi = i;
        const it = open.items.find(it => it.index === i);
        if (it) it.el.scrollIntoView({block: 'nearest'});
      };
      const step = d => {
        const enabled = open.items.filter(it => !it.disabled);
        if (!enabled.length) return;
        let k = enabled.findIndex(it => it.index === open.hi);
        k = k < 0 ? 0 : Math.max(0, Math.min(enabled.length - 1, k + d));
        highlight(enabled[k].index);
      };

      const show = s => {
        close();
        const r = s.getBoundingClientRect();
        const cs = getComputedStyle(s);
        const host = document.createElement('div');
        host.style.cssText = 'all: initial; position: fixed; inset: 0; z-index: 2147483647; pointer-events: none;';
        const root = host.attachShadow({mode: 'open'});
        const dark = matchMedia('(prefers-color-scheme: dark)').matches;
        root.innerHTML = `<style>
          .list { position: fixed; pointer-events: auto; overflow-y: auto; box-sizing: border-box;
            background: ${dark ? '#2b2b2d' : '#fff'}; color: ${dark ? '#eee' : '#111'};
            border: 1px solid ${dark ? '#555' : '#bbb'}; border-radius: 6px; padding: 4px 0;
            box-shadow: 0 6px 20px rgba(0,0,0,.35); font: ${cs.fontSize} -apple-system, system-ui, sans-serif; }
          .opt { padding: 3px 12px 3px 22px; white-space: pre; cursor: default; position: relative; }
          .opt.sel::before { content: '✓'; position: absolute; left: 7px; }
          .opt.hi { background: #0a64d8; color: #fff; }
          .opt.dis { opacity: .45; }
          .grp { padding: 4px 10px 2px; font-weight: 600; opacity: .7; }
          .grp ~ .opt.ingrp { padding-left: 30px; }
          .grp ~ .opt.ingrp.sel::before { left: 15px; }
        </style><div class="list"></div>`;
        const list = root.querySelector('.list');
        const items = [];
        let group = null;
        Array.from(s.options).forEach((o, index) => {
          const g = o.parentElement instanceof HTMLOptGroupElement ? o.parentElement : null;
          if (g && g !== group) {
            const h = document.createElement('div');
            h.className = 'grp';
            h.textContent = g.label;
            list.appendChild(h);
          }
          group = g;
          const el = document.createElement('div');
          const disabled = o.disabled || (g && g.disabled);
          el.className = 'opt' + (o.selected ? ' sel' : '') + (disabled ? ' dis' : '') + (g ? ' ingrp' : '');
          el.textContent = o.label || o.text || ' ';
          if (o.hidden) el.style.display = 'none';
          if (!disabled) {
            el.addEventListener('mousemove', () => highlight(index));
            el.addEventListener('mouseup', e => { e.preventDefault(); choose(index); });
          }
          el.addEventListener('mousedown', e => e.preventDefault());
          list.appendChild(el);
          items.push({index, el, disabled});
        });
        (document.body || document.documentElement).appendChild(host);

        // Below the select, or above it when there's more room there.
        const vw = innerWidth, vh = innerHeight, gap = 2, margin = 6;
        const below = vh - r.bottom - gap - margin, above = r.top - gap - margin;
        const natural = list.scrollHeight + 2;
        const downward = natural <= below || below >= above;
        const h = Math.min(natural, Math.max(downward ? below : above, 80));
        const w = Math.min(Math.max(r.width, list.scrollWidth + 4), vw - 2 * margin);
        list.style.width = w + 'px';
        list.style.maxHeight = h + 'px';
        list.style.left = Math.max(margin, Math.min(r.left, vw - w - margin)) + 'px';
        list.style.top = (downward ? r.bottom + gap : Math.max(margin, r.top - gap - h)) + 'px';

        open = {select: s, host, list, items, hi: -1};
        highlight(s.selectedIndex);
        addEventListener('scroll', onScroll, true);
        addEventListener('resize', close, true);
        addEventListener('blur', close, true);
      };

      addEventListener('mousedown', e => {
        if (open) {
          if (e.composedPath().includes(open.host)) return;
          const s = open.select;
          close();
          if (e.target === s) { e.preventDefault(); s.focus({preventScroll: true}); return; }
        }
        const s = e.target;
        if (e.button !== 0 || !isPopup(s)) return;
        e.preventDefault();
        s.focus({preventScroll: true});
        show(s);
      }, true);

      addEventListener('keydown', e => {
        if (open) {
          const enabled = open.items.filter(it => !it.disabled);
          switch (e.key) {
            case 'ArrowDown': step(1); break;
            case 'ArrowUp': step(-1); break;
            case 'Home': if (enabled.length) highlight(enabled[0].index); break;
            case 'End': if (enabled.length) highlight(enabled[enabled.length - 1].index); break;
            case 'PageDown': step(10); break;
            case 'PageUp': step(-10); break;
            case 'Enter': case ' ': if (open.hi >= 0) choose(open.hi); else close(); break;
            case 'Escape': case 'Tab': close(); if (e.key === 'Tab') return; break;
            default: {
              if (e.key.length !== 1 || e.metaKey || e.ctrlKey) return;
              const k = e.key.toLowerCase();
              const start = enabled.findIndex(it => it.index === open.hi);
              const order = enabled.slice(start + 1).concat(enabled.slice(0, start + 1));
              const hit = order.find(it => it.el.textContent.trim().toLowerCase().startsWith(k));
              if (hit) highlight(hit.index);
            }
          }
          e.preventDefault();
          e.stopPropagation();
          return;
        }
        const s = e.target;
        if (!isPopup(s) || e.metaKey || e.ctrlKey) return;
        if (e.key === ' ' || e.key === 'Enter' || e.key === 'ArrowDown' || e.key === 'ArrowUp') {
          e.preventDefault();
          e.stopPropagation();
          show(s);
        }
      }, true);
    })();
    """

    /// Closes any native menu as soon as it opens: context menus and anything
    /// the script above misses would otherwise show on the real screen.
    @MainActor
    static func suppressNativeMenus() {
        NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil
        ) { note in
            guard let menu = note.object as? NSMenu else { return }
            Log.write("closing native menu (\(menu.items.count) items)")
            DispatchQueue.main.async { menu.cancelTrackingWithoutAnimation() }
            menu.cancelTrackingWithoutAnimation()
        }
    }
}
