// The Doorbell tab: two independent sections, each with its own switch,
// grant row, timing rows, its own doorbells and its own add area. The
// switch row is the section's heading (the setting's title with its
// switch, the same row the device shows) and carries the one-line
// explanation; everything else in the section follows the switch in
// place, so both sections can be on at once and turning one off hides
// only that section's own children. The setting rows go through the
// same settingRow() the generic path uses, so saving works exactly as
// for every other setting; the lists come from the doorbellSignatures
// command, which owns the status wording, and reload every 5 seconds
// while this tab is the visible one. The tab's text is English only.

import { cmd, state } from './core.js';
import { pickEntity } from './entity_picker.js';
import { settingRow } from './rows.js';
import { messageBox, modalShell, showToast } from './widgets.js';

const POLL_MS = 5000;
const EUFY_PACKAGE = 'com.oceanwing.battery.cam';

// The grant-row builder and the notification and click-access polls,
// handed over by settings.js, which shares them with the other tabs'
// grant cards.
let grants = null;
// The sections as last rendered: the switch's key, the children that
// follow it, and the setting rows the switch gates.
let sections = [];
// The list bodies and the Eufy add button as last rendered.
let lists = null;
// The sensor rows by doorbell id, for the Test flow's live messages.
let sensorItems = new Map();
// The doorbells as last loaded; null until the first load answers.
let doorbells = null;
let loadFailed = false;
// One command at a time: while one runs, every list and add button is
// disabled and the poll leaves the lists alone.
let busy = false;
// A list load in flight, so the poll can never stack.
let loading = false;
// What a Test left under its row, kept so the list's repaints (the
// 5-second reload among them) do not take the outcome away.
let testOutcome = null;
let pollTimer = null;
let wired = false;

const tabEl = () => document.getElementById('tab-doorbell');
const def = (key) => (state.settings || []).find((s) => s.key === key) || null;
const switchOn = (key) => {
  const cb = tabEl()?.querySelector(`[data-key="${key}"] input[type="checkbox"]`);
  return !!cb && cb.checked;
};

// A small button for the lists and add areas, born disabled while a
// command runs.
const button = (text, onClick) => {
  const b = document.createElement('button');
  b.className = 'btn-ghost';
  b.textContent = text;
  b.disabled = busy;
  b.addEventListener('click', onClick);
  return b;
};

// The state mark: a check when ready, a clock while untested or
// waiting, a cross when failing, in the colours app.css defines.
const CLOCK_GLYPH = '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3.5 2"/>';
const STATE_MARKS = {
  ready: { color: 'var(--ok)', glyph: '<path d="m5 12.5 4.5 4.5L19 7.5"/>' },
  untested: { color: 'var(--muted)', glyph: CLOCK_GLYPH },
  waiting: { color: 'var(--muted)', glyph: CLOCK_GLYPH },
  failing: { color: 'var(--error)', glyph: '<path d="m6 6 12 12M18 6 6 18"/>' },
};
const stateMark = (stateName) => {
  const mark = STATE_MARKS[stateName] || STATE_MARKS.waiting;
  const el = document.createElement('span');
  el.className = 'doorbell-mark';
  el.style.cssText = 'display:inline-flex; width:17px; height:17px; flex:none';
  el.style.color = mark.color;
  // A fixed glyph, never text from the device.
  el.innerHTML = '<svg viewBox="0 0 24 24" width="17" height="17" fill="none"'
    + ' stroke="currentColor" stroke-width="2" stroke-linecap="round"'
    + ' stroke-linejoin="round">' + mark.glyph + '</svg>';
  return el;
};

// One command at a time. Resolves to the command's data, and throws
// with the kiosk's own error message when it refuses.
const run = async (name, body) => {
  if (busy) throw new Error('Another change is still running. Try again in a moment.');
  setBusy(true);
  try {
    const out = await cmd(name, body || {});
    if (!out || out.ok !== true) {
      throw new Error(out?.error || 'Could not reach the kiosk. Try again.');
    }
    return out.data;
  } finally {
    setBusy(false);
  }
};

const setBusy = (on) => {
  busy = on;
  tabEl()?.querySelectorAll('.doorbell-list button, .doorbell-add button')
    .forEach((b) => { b.disabled = on; });
};

// The doorbells of both sections, from the command that owns the
// status wording. Skipped while a command runs: the rows hold that
// command's own message (a Test's progress and outcome), and a
// repaint would take it away.
const loadDoorbells = async () => {
  if (loading || busy) return;
  loading = true;
  let failed = false;
  try {
    const out = await cmd('doorbellSignatures');
    if (out?.ok === true && Array.isArray(out.data)) {
      doorbells = out.data.filter((d) => d && typeof d === 'object');
      loadFailed = false;
    } else {
      failed = true;
    }
  } catch (_) {
    failed = true;
  }
  loading = false;
  if (failed && doorbells === null) loadFailed = true;
  paintLists();
};

const paintLists = () => {
  if (!lists) return;
  const all = doorbells || [];
  sensorItems = new Map();
  paintList('notification', all.filter((d) => d.kind !== 'sensor'));
  paintList('sensor', all.filter((d) => d.kind === 'sensor'));
  if (lists.eufy) lists.eufy.hidden = all.some((d) => d.package === EUFY_PACKAGE);
};

const paintList = (kind, list) => {
  const body = lists[kind];
  if (!body) return;
  body.textContent = '';
  if (doorbells === null) {
    if (loadFailed) {
      const line = document.createElement('div');
      line.className = 'desc';
      line.textContent = 'Could not load the doorbells.';
      body.appendChild(line);
    }
    return;
  }
  if (!list.length) {
    const line = document.createElement('div');
    line.className = 'desc';
    line.textContent = 'No doorbell added yet.';
    body.appendChild(line);
    return;
  }
  for (const doorbell of list) {
    const item = doorbellRow(kind, doorbell);
    body.appendChild(item);
    if (kind !== 'sensor') continue;
    sensorItems.set(doorbell.id || '', item);
    if (testOutcome && testOutcome.id === (doorbell.id || '')) testOutcome.fill(item);
  }
};

// One doorbell: its label with the state mark, the status text under
// it, and the buttons its section offers. Every word of it comes from
// the kiosk, so it all goes through textContent.
const doorbellRow = (kind, doorbell) => {
  const item = document.createElement('div');
  const row = document.createElement('div');
  row.className = 'row';
  const info = document.createElement('div');
  info.className = 'info';
  const name = document.createElement('div');
  name.className = 'name';
  name.style.cssText = 'display:flex; align-items:center; gap:7px; min-width:0';
  name.appendChild(stateMark(doorbell.state));
  const label = document.createElement('span');
  label.style.cssText = 'overflow:hidden; text-overflow:ellipsis; white-space:nowrap';
  label.textContent = doorbell.label || doorbell.package || '';
  name.appendChild(label);
  const status = document.createElement('div');
  status.className = 'desc';
  status.textContent = doorbell.statusText || '';
  info.append(name, status);
  row.appendChild(info);
  const actions = document.createElement('div');
  actions.style.cssText = 'display:flex; gap:8px; align-items:center; flex:none';
  if (kind === 'sensor') {
    actions.append(
      button('Test', () => { void testDoorbell(doorbell); }),
      button('Edit', () => editDoorbell(doorbell)));
  }
  actions.appendChild(button('Remove', () => { void removeDoorbell(doorbell); }));
  row.appendChild(actions);
  item.appendChild(row);
  return item;
};

// The line under a row: a Test's progress and outcome, with the card
// names a miss offers. Built fresh each time, so it never stacks.
const setDetail = (item, build) => {
  if (!item) return;
  item.querySelector('.doorbell-detail')?.remove();
  const detail = document.createElement('div');
  detail.className = 'doorbell-detail desc';
  detail.style.cssText = 'white-space:pre-line; padding:0 0 13px';
  build(detail);
  item.appendChild(detail);
};

// Why a Test did not open the doorbell, one line per result.
const TEST_REASONS = {
  wrong_app: 'The doorbell app did not come to the front.',
  service_off: 'Doorbell click access is off. Turn it on from the click access row above.',
  launch_failed: 'The app could not be opened.',
  timeout: 'The click service did not answer.',
};

const TESTING_TEXT = 'Testing... the tablet opens the doorbell app and tries to tap'
  + ' the camera. This takes up to 30 seconds.';

// A Test: the tablet opens the doorbell app and taps the taught card,
// which takes up to ~40 seconds. The row says so while it runs, then
// the outcome: the ready line on a click, the status text and the
// reason on a miss, with the card names the app showed as one-tap
// corrections. Then the list reloads.
const testDoorbell = async (doorbell) => {
  const id = doorbell.id || '';
  const label = doorbell.label || doorbell.package || 'The doorbell';
  const testing = (item) => setDetail(item, (detail) => {
    detail.textContent = TESTING_TEXT;
  });
  // Said before the command runs, and re-attached by every repaint
  // while it runs (the page can rebuild around a slow Test).
  testOutcome = { id, fill: testing };
  testing(sensorItems.get(id));
  let data = null;
  let error = null;
  try {
    data = await run('doorbellTestOpen', { id });
  } catch (e) {
    error = e?.message || 'The test could not run. Try again.';
  }
  testOutcome = { id, fill: (item) => setDetail(item, (detail) => {
    if (error) {
      detail.textContent = error;
      return;
    }
    const result = data?.result || '';
    if (result === 'clicked') {
      detail.textContent = `The tap worked. ${label} is ready.`;
      return;
    }
    const lines = [data?.text || ''];
    lines.push(result === 'not_found'
      ? `The card "${doorbell.clickLabel || ''}" was not found on the app's screen.`
      : TEST_REASONS[result] || '');
    detail.textContent = lines.filter(Boolean).join('\n');
    if (result !== 'not_found' || !Array.isArray(data?.cards) || !data.cards.length) return;
    const shown = document.createElement('div');
    shown.textContent = 'Cards the app showed:';
    detail.appendChild(shown);
    const cards = document.createElement('div');
    cards.style.cssText = 'display:flex; flex-wrap:wrap; gap:8px; margin-top:6px';
    for (const name of data.cards) {
      cards.appendChild(button(name, async () => {
        try {
          await run('doorbellUpdateSignature', { id, clickLabel: name });
        } catch (e) {
          showToast({ title: 'Could not change the card',
            message: e?.message || '', kind: 'error' });
          return;
        }
        await testDoorbell({ ...doorbell, clickLabel: name });
      }));
    }
    detail.appendChild(cards);
  }) };
  testOutcome.fill(sensorItems.get(id));
  await loadDoorbells();
};

// The edit form of a sensor & tap doorbell: its name and its ringing
// sensor. The card is taught on the tablet, so it has no field here;
// the kiosk's own validation messages come back to the form.
const editDoorbell = (doorbell) => {
  const shell = modalShell({
    title: `Edit ${doorbell?.label || doorbell?.package || 'doorbell'}`,
    width: 520,
    onDismiss: () => shell.close(),
  });
  const problem = document.createElement('div');
  problem.className = 'desc';
  problem.style.cssText = 'color:var(--error); margin-top:2px';
  const field = (nameText, control) => {
    const wrap = document.createElement('label');
    wrap.className = 'form-field';
    const title = document.createElement('span');
    title.className = 'desc';
    title.textContent = nameText;
    wrap.append(title, control);
    shell.body.appendChild(wrap);
  };
  const input = (value) => {
    const box = document.createElement('input');
    box.className = 'field';
    box.type = 'text';
    box.value = value || '';
    return box;
  };
  const name = input(doorbell?.label);
  field('Name', name);
  let entity = doorbell?.entity || '';
  const entityText = document.createElement('span');
  entityText.className = 'device';
  entityText.style.cssText =
    'flex:1; min-width:0; overflow:hidden; text-overflow:ellipsis; white-space:nowrap';
  const paintEntity = () => { entityText.textContent = entity || 'None'; };
  paintEntity();
  const pick = document.createElement('button');
  pick.className = 'btn-ghost';
  pick.style.flex = 'none';
  pick.textContent = 'Pick';
  pick.addEventListener('click', async () => {
    const picked = await pickEntity({ title: 'Ringing sensor', selected: entity || null,
      domains: ['binary_sensor'], allowClear: true });
    if (picked) { entity = picked.id || ''; paintEntity(); }
  });
  const entityRow = document.createElement('div');
  entityRow.style.cssText = 'display:flex; gap:10px; align-items:center; min-width:0';
  entityRow.append(entityText, pick);
  field('Ringing sensor', entityRow);
  shell.body.appendChild(problem);
  const save = document.createElement('button');
  save.className = 'btn-primary';
  save.textContent = 'Save';
  save.addEventListener('click', async () => {
    problem.textContent = '';
    // Only the keys that changed; a key left out keeps its value.
    const body = { id: doorbell?.id || '' };
    if (name.value.trim() !== (doorbell?.label || '')) body.label = name.value.trim();
    if (entity !== (doorbell?.entity || '')) body.entity = entity.trim();
    save.disabled = true;
    try {
      await run('doorbellUpdateSignature', body);
      shell.close();
      await loadDoorbells();
    } catch (error) {
      problem.textContent = error?.message || 'Could not save. Try again.';
      save.disabled = false;
    }
  });
  const cancel = document.createElement('button');
  cancel.className = 'btn-text';
  cancel.textContent = 'Cancel';
  cancel.addEventListener('click', () => shell.close());
  shell.foot.append(cancel, save);
};

// Remove asks first, then forgets the doorbell on the kiosk.
const removeDoorbell = async (doorbell) => {
  const label = doorbell?.label || doorbell?.package || 'this doorbell';
  const pick = await messageBox({
    title: 'Remove doorbell',
    message: `Remove ${label}? The kiosk stops answering its rings.`,
    buttons: ['Remove', 'Cancel'],
    buttonText: (text) => text,
  });
  if (pick !== 'Remove') return;
  try {
    await run('doorbellRemoveSignature', { id: doorbell?.id || '' });
    if (testOutcome && testOutcome.id === (doorbell?.id || '')) testOutcome = null;
    await loadDoorbells();
  } catch (error) {
    showToast({ title: 'Could not remove the doorbell',
      message: error?.message || '', kind: 'error' });
  }
};

// The section's doorbells: a heading line and the rows under it.
const listArea = (kind) => {
  const wrap = document.createElement('div');
  wrap.className = 'doorbell-list';
  const title = document.createElement('div');
  title.className = 'desc';
  title.style.cssText = 'margin:14px 0 2px; font-weight:600';
  title.textContent = 'Doorbells';
  const body = document.createElement('div');
  wrap.append(title, body);
  lists[kind] = body;
  return wrap;
};

// What each section says about adding: the notification section offers
// the Eufy preset until a doorbell with that package is saved; the
// sensor section has no form at all, because teaching the card needs
// the tablet.
const addArea = (kind) => {
  const wrap = document.createElement('div');
  wrap.className = 'doorbell-add';
  if (kind === 'notification') {
    wrap.style.cssText =
      'display:flex; flex-direction:column; gap:8px; align-items:flex-start; padding:13px 0 0';
    const add = button('Add Eufy Security', () => { void addEufy(); });
    wrap.appendChild(add);
    lists.eufy = add;
    const hint = document.createElement('div');
    hint.className = 'desc';
    hint.textContent = 'Learning another doorbell from its ring needs the tablet:'
      + ' Settings > Doorbell > Add doorbell.';
    wrap.appendChild(hint);
    return wrap;
  }
  wrap.className = 'doorbell-add desc';
  wrap.style.cssText = 'padding:13px 0 0';
  wrap.textContent = 'Adding a sensor & tap doorbell needs the tablet, because you'
    + ' teach it by tapping the camera in the doorbell app. On the tablet:'
    + ' Settings > Doorbell > Add doorbell. Once added it appears here, and you'
    + ' can test, edit and remove it from this page.';
  return wrap;
};

const addEufy = async () => {
  try {
    await run('doorbellAddSignature', {
      label: 'Eufy Security',
      package: EUFY_PACKAGE,
      channelPrefix: 'com.ocean.battery.cam.ring',
    });
    await loadDoorbells();
  } catch (error) {
    showToast({ title: 'Could not add the doorbell',
      message: error?.message || '', kind: 'error' });
  }
};

// Follow both switches in place: the children hide, and the gated rows
// come and go, exactly as the generic path would show them (the
// switch's own save then runs the generic gated sync, which finds
// nothing left to do). Runs synchronously off the change event, ahead
// of that save's answer.
const sync = () => {
  for (const one of sections) {
    const on = switchOn(one.switchKey);
    // Back to front, so each row lands in front of the one after it.
    for (let i = one.gated.length - 1; i >= 0; i--) {
      const gated = one.gated[i];
      if (on === gated.el.isConnected) continue;
      if (!on) { gated.el.remove(); continue; }
      const d = def(gated.key);
      const next = i + 1 < one.gated.length ? one.gated[i + 1].el : one.anchor;
      if (!d || !next?.parentNode) continue;
      gated.el = settingRow(d);
      next.parentNode.insertBefore(gated.el, next);
    }
    one.children.forEach((el) => el.classList.toggle('hidden', !on));
  }
};

// One section: a card whose first row is the switch (the section's
// heading, carrying the one-line explanation), then the grant row, the
// timing rows the switch gates, the doorbells and the add area.
const section = (switchKey, explanation, build) => {
  const card = document.createElement('div');
  card.className = 'card';
  const switchDef = def(switchKey);
  if (switchDef) {
    // The explanation stands in for the schema's description: the
    // section says what it does in one line, not two that mean the
    // same thing.
    const switchRow = settingRow({ ...switchDef, description: explanation });
    card.appendChild(switchRow);
    // A failed save snaps the switch back with no change event: the
    // row's own error line is the mutation to re-follow it by.
    new MutationObserver(() => sync()).observe(switchRow, { childList: true });
  }
  const children = [];
  const gated = [];
  let anchorIndex = null;
  const child = (el) => { children.push(el); card.appendChild(el); return el; };
  // A setting row the switch gates: present only while the switch is
  // on, like every dependsOn row.
  const gatedRow = (key) => {
    const d = def(key);
    if (!d) return;
    if (anchorIndex === null) anchorIndex = children.length;
    const el = settingRow(d);
    gated.push({ key, el });
    card.appendChild(el);
  };
  build(child, gatedRow);
  sections.push({
    switchKey,
    children,
    gated,
    anchor: children[anchorIndex ?? children.length] || null,
  });
  tabEl().appendChild(card);
};

// The lists reload every 5 seconds while the Doorbell tab is the
// visible one, and stop the moment it is not (or the page is hidden):
// one timer for the whole tab, so the reloads can never stack.
const syncPolling = () => {
  const want = !document.hidden && !!lists && !!tabEl()?.classList.contains('active');
  if (want === (pollTimer !== null)) return;
  if (want) {
    pollTimer = setInterval(() => { void loadDoorbells(); }, POLL_MS);
  } else {
    clearInterval(pollTimer);
    pollTimer = null;
  }
};

// The tab element lives as long as the page does, so the delegated
// listeners are wired once; they read the sections as last rendered.
const wire = () => {
  if (wired) return;
  wired = true;
  tabEl().addEventListener('change', (e) => {
    const key = e.target.closest?.('[data-key]')?.dataset.key;
    if (key === 'doorbell.enabled' || key === 'doorbell.sensor_enabled') sync();
  });
  document.addEventListener('ks-route', syncPolling);
  document.addEventListener('visibilitychange', syncPolling);
};

// Draws the tab. settings.js calls this on every render, handing over
// the shared grant-row builder and the notification and click-access
// polls it draws with.
export function renderDoorbellTab(helpers) {
  grants = helpers;
  const tab = tabEl();
  if (!tab) return;
  // A device that serves no doorbell settings keeps whatever the
  // generic path drew (its empty-state card).
  if (!def('doorbell.enabled') && !def('doorbell.sensor_enabled')) return;
  wire();
  tab.innerHTML = '';
  sections = [];
  lists = {};
  section('doorbell.enabled',
    'When your doorbell app shows its ring notification, open that camera over the kiosk.',
    (child, gatedRow) => {
      child(grants.permRow('Notification access',
        'The doorbell sees the rings the doorbell app announces.',
        'Without this the doorbell sees no rings and never opens its app. The grant screen appears on the tablet.',
        'Grant on device', grants.grantNotifications, grants.pollNotifications));
      gatedRow('doorbell.return_seconds');
      child(listArea('notification'));
      child(addArea('notification'));
    });
  section('doorbell.sensor_enabled',
    "When a Home Assistant sensor says the doorbell is ringing, open the doorbell app and tap the camera's card.",
    (child, gatedRow) => {
      child(grants.permRow('Doorbell click access',
        'The kiosk can tap your doorbell camera.',
        'Without this the kiosk cannot tap the camera. Turn it on in Android Accessibility settings on the tablet (find Kiosk Satellite there).',
        'Open on device', grants.openClickSettings, grants.pollClickAccess));
      gatedRow('doorbell.click_delay_seconds');
      gatedRow('doorbell.sensor_return_seconds');
      child(listArea('sensor'));
      child(addArea('sensor'));
    });
  sync();
  paintLists();
  void loadDoorbells();
  syncPolling();
}
