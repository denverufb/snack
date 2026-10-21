/* Snack Pass: Supabase-backed, barcode-scanner friendly point-of-sale app.
   Scan recognition is local; every financial change is atomic in Postgres.
   Requires schema.sql and a staff account created per README.md. */
(() => {
  'use strict';
  const config = window.SNACK_PASS_CONFIG || {};
  const el = id => document.getElementById(id);
  const escapeHTML = text => String(text ?? '').replace(/[&<>"']/g, c => ({
    '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;'
  }[c]));
  const uuid = () => crypto.randomUUID();
  const dbReady = !!(window.supabase && config.supabaseUrl && config.supabaseAnonKey &&
    !config.supabaseUrl.includes('YOUR-PROJECT-ID') && !config.supabaseAnonKey.startsWith('YOUR-'));
  const db = dbReady ? window.supabase.createClient(config.supabaseUrl, config.supabaseAnonKey, {
    auth: { autoRefreshToken: true, persistSession: true, detectSessionInUrl: true }
  }) : null;
  const state = {
    students: [], snacks: [], transactions: [], selectedStudentBarcode: null,
    tab: 'checkout', feed: [], queue: [], processing: false, loggedIn: false,
    startInProgress: false, subscription: null, busyActions: new Set(),
    lastScan: { code: '', time: 0 }
  };
  let toastTimeout;
  const studentByBarcode = code => state.students.find(x => x.barcode === code);
  const snackByBarcode = code => state.snacks.find(x => x.barcode === code);
  const studentById = id => state.students.find(x => x.id === id);
  const snackById = id => state.snacks.find(x => x.id === id);
  const selectedStudent = () => studentByBarcode(state.selectedStudentBarcode);
  const errText = error => (error && error.message) || 'Unknown error. Please retry.';

  function toast(message, error = false) {
    const target = el('toast');
    target.textContent = message;
    target.classList.toggle('error', error);
    target.classList.remove('hidden');
    clearTimeout(toastTimeout);
    toastTimeout = setTimeout(() => target.classList.add('hidden'), 4300);
  }
  function setStatus(message, kind = '') {
    const target = el('checkout-status');
    target.className = 'status' + (kind ? ' ' + kind : '');
    target.textContent = message;
  }
  function focusScanner() {
    if (state.tab === 'checkout' && state.loggedIn && !el('tab-checkout').classList.contains('hidden')) {
      el('scan').focus({ preventScroll: true });
    }
  }
  function setConnection(message) { el('connection').textContent = message; }
  function setTab(name) {
    state.tab = name;
    document.querySelectorAll('[data-tab]').forEach(button =>
      button.classList.toggle('active', button.dataset.tab === name));
    for (const tab of ['checkout', 'students', 'snacks', 'activity']) {
      el('tab-' + tab).classList.toggle('hidden', tab !== name);
    }
    if (name === 'checkout') setTimeout(focusScanner, 0);
    if (name === 'activity') renderActivity();
  }
  function updateRow(collection, row) {
    const items = state[collection];
    const idx = items.findIndex(x => x.id === row.id);
    if (idx < 0) items.push(row);
    else items[idx] = { ...items[idx], ...row };
  }
  async function refreshReferenceData() {
    const [studentsResult, snacksResult] = await Promise.all([
      db.from('students').select('id,barcode,full_name,points,active,created_at').order('full_name').limit(1000),
      db.from('snacks').select('id,barcode,name,price,stock,active,created_at').order('name').limit(1000)
    ]);
    if (studentsResult.error) throw studentsResult.error;
    if (snacksResult.error) throw snacksResult.error;
    state.students = studentsResult.data || [];
    state.snacks = snacksResult.data || [];
    renderAll();
  }
  async function refreshHistory() {
    const { data, error } = await db.from('transactions')
      .select('id,request_id,kind,student_id,snack_id,delta_points,balance_after,related_transaction_id,note,staff_id,created_at')
      .order('created_at', { ascending: false }).limit(200);
    if (error) throw error;
    state.transactions = data || [];
    renderActivity();
    renderStats();
  }
  async function refreshAll() {
    await Promise.all([refreshReferenceData(), refreshHistory()]);
  }
  function startRealtime() {
    if (state.subscription) db.removeChannel(state.subscription);
    state.subscription = db.channel('snack-pass-changes')
      .on('postgres_changes', { event: '*', schema: 'public', table: 'students' }, payload => {
        if (payload.new?.id) { updateRow('students', payload.new); renderAll(); }
      })
      .on('postgres_changes', { event: '*', schema: 'public', table: 'snacks' }, payload => {
        if (payload.new?.id) { updateRow('snacks', payload.new); renderAll(); }
      })
      .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'transactions' }, () => {
        if (state.tab === 'activity') refreshHistory().catch(() => {});
      })
      .subscribe();
  }
  async function start(session) {
    if (!session) { stop(); return; }
    if (state.loggedIn || state.startInProgress) return;
    state.startInProgress = true;
    try {
      const { data, error } = await db.rpc('is_staff');
      if (error) throw error;
      if (!data) {
        el('auth-message').textContent = 'This account is not authorized. Ask an administrator to add it to the staff table.';
        await db.auth.signOut();
        return;
      }
      state.loggedIn = true;
      el('auth').classList.add('hidden');
      el('app').classList.remove('hidden');
      el('logout').classList.remove('hidden');
      setConnection('Connected');
      await refreshAll();
      startRealtime();
      focusScanner();
    } catch (error) {
      state.loggedIn = false;
      el('app').classList.add('hidden');
      el('auth').classList.remove('hidden');
      el('auth-message').textContent = errText(error);
      setConnection('Connection error');
    } finally { state.startInProgress = false; }
  }
  function stop() {
    state.loggedIn = false;
    state.selectedStudentBarcode = null;
    state.queue = [];
    state.feed = [];
    state.students = [];
    state.snacks = [];
    state.transactions = [];
    if (state.subscription && db) db.removeChannel(state.subscription);
    state.subscription = null;
    el('auth').classList.remove('hidden');
    el('app').classList.add('hidden');
    el('logout').classList.add('hidden');
    setConnection('Sign in required');
  }

  function renderStats() {
    const activeStudents = state.students.filter(x => x.active);
    el('stat-students').textContent = activeStudents.length.toLocaleString();
    el('stat-snacks').textContent = state.snacks.filter(x => x.active && x.stock !== 0).length.toLocaleString();
    el('stat-points').textContent = activeStudents.reduce((s, x) => s + x.points, 0).toLocaleString();
    const today = new Date().toDateString();
    el('stat-today').textContent = state.transactions.filter(x =>
      x.kind === 'purchase' && new Date(x.created_at).toDateString() === today).length;
  }
  function renderStudentBox() {
    const st = selectedStudent();
    const box = el('student-box');
    box.classList.toggle('found', !!st?.active);
    if (!st || !st.active) {
      box.innerHTML = '<div class="avatar">?</div><div><div class="scanned-name">No student selected</div><div class="small">Start by scanning a student ID</div></div>';
      return;
    }
    const initials = st.full_name.trim().split(/\s+/).slice(0, 2).map(x => x[0] || '').join('').toUpperCase();
    box.innerHTML = `<div class="avatar">${escapeHTML(initials)}</div><div><div class="scanned-name">${escapeHTML(st.full_name)}</div><div class="small mono">${escapeHTML(st.barcode)}</div></div><div class="balance"><strong>${st.points}</strong><span>points</span></div>`;
  }
  function renderFeed() {
    const root = el('scan-feed');
    if (!state.feed.length) {
      root.innerHTML = '<p class="empty">Your scanned snacks will appear here.</p>';
      return;
    }
    root.innerHTML = state.feed.slice(0, 10).map(item => `<div class="recent-item"><div class="avatar" style="width:35px;height:35px;font-size:14px">${item.success ? '✓' : '!'}</div><div style="min-width:0;flex:1"><strong>${escapeHTML(item.title)}</strong><div class="small">${escapeHTML(item.detail)}</div></div><span class="tag ${item.success ? 'green' : 'orange'}">${item.success ? 'Saved' : 'Issue'}</span></div>`).join('');
  }
  function addFeed(title, detail, success) {
    state.feed.unshift({ title, detail, success });
    state.feed = state.feed.slice(0, 30);
    renderFeed();
  }
  function renderStudents() {
    const q = el('student-search').value.trim().toLowerCase();
    const filtered = state.students.filter(s => (s.full_name + ' ' + s.barcode).toLowerCase().includes(q));
    el('student-rows').innerHTML = filtered.length ? filtered.map(st => `<tr class="${st.active ? '' : 'inactive'}"><td><strong>${escapeHTML(st.full_name)}</strong></td><td class="mono">${escapeHTML(st.barcode)}</td><td><strong>${st.points}</strong></td><td><span class="tag ${st.active ? 'green' : ''}">${st.active ? 'Active' : 'Inactive'}</span></td><td class="actions"><button class="btn smallbtn" data-student-action="checkout" data-id="${st.id}" ${!st.active ? 'disabled' : ''}>Use</button> <button class="btn smallbtn" data-student-action="adjust" data-id="${st.id}">± Points</button> <button class="btn smallbtn" data-student-action="toggle" data-id="${st.id}">${st.active ? 'Deactivate' : 'Reactivate'}</button></td></tr>`).join('') : '<tr><td colspan="5" class="empty">No students match your search.</td></tr>';
  }
  function renderSnacks() {
    const q = el('snack-search').value.trim().toLowerCase();
    const filtered = state.snacks.filter(s => (s.name + ' ' + s.barcode).toLowerCase().includes(q));
    el('snack-rows').innerHTML = filtered.length ? filtered.map(sn => `<tr class="${sn.active ? '' : 'inactive'}"><td><strong>${escapeHTML(sn.name)}</strong></td><td class="mono">${escapeHTML(sn.barcode)}</td><td>${sn.price} pt</td><td>${sn.stock === null ? 'Untracked' : sn.stock}</td><td><span class="tag ${sn.active ? 'green' : ''}">${sn.active ? 'Active' : 'Inactive'}</span></td><td class="actions"><button class="btn smallbtn" data-snack-action="edit" data-id="${sn.id}">Edit</button> <button class="btn smallbtn" data-snack-action="toggle" data-id="${sn.id}">${sn.active ? 'Deactivate' : 'Reactivate'}</button></td></tr>`).join('') : '<tr><td colspan="6" class="empty">No snacks match your search.</td></tr>';
  }
  function renderActivity() {
    const kind = el('activity-kind').value;
    const rows = state.transactions.filter(t => kind === 'all' || t.kind === kind);
    const refunded = new Set(state.transactions.filter(t => t.kind === 'refund').map(t => t.related_transaction_id));
    el('activity-rows').innerHTML = rows.length ? rows.map(t => {
      const student = studentById(t.student_id);
      const snack = snackById(t.snack_id);
      const related = t.kind === 'purchase' && refunded.has(t.id);
      const refundButton = t.kind === 'purchase' && !related
        ? `<button class="btn smallbtn" data-refund-id="${t.id}">Refund</button>`
        : (related ? '<span class="tag">Refunded</span>' : '');
      return `<tr><td>${escapeHTML(new Date(t.created_at).toLocaleString())}</td><td>${escapeHTML(student?.full_name || 'Student #' + t.student_id)}</td><td><span class="tag">${escapeHTML(t.kind)}</span></td><td>${escapeHTML(snack?.name || t.note || '—')}</td><td><strong style="color:${t.delta_points < 0 ? '#a82b35' : '#077b58'}">${t.delta_points > 0 ? '+' : ''}${t.delta_points}</strong></td><td>${t.balance_after}</td><td>${refundButton}</td></tr>`;
    }).join('') : '<tr><td colspan="7" class="empty">No transactions to show.</td></tr>';
  }
  function renderAll() { renderStats(); renderStudentBox(); renderStudents(); renderSnacks(); renderActivity(); }

  function selectStudent(st) {
    if (!st.active) { toast('Student is inactive.', true); return; }
    state.selectedStudentBarcode = st.barcode;
    renderStudentBox();
    setStatus(`${st.full_name} loaded. Scan a snack.`, 'good');
  }
  function scanBarcode(raw) {
    const code = String(raw).trim();
    if (!code) return;
    const now = Date.now();
    if (code === state.lastScan.code && now - state.lastScan.time < 175) return;
    state.lastScan = { code, time: now };
    const st = studentByBarcode(code);
    if (st) { selectStudent(st); return; }
    const sn = snackByBarcode(code);
    if (!sn) {
      addFeed('Barcode not recognized', code, false);
      setStatus(`Unknown barcode: ${code}. Register the student or snack first.`, 'bad');
      return;
    }
    if (!sn.active) { setStatus(`${sn.name} is inactive.`, 'bad'); return; }
    const student = selectedStudent();
    if (!student || !student.active) {
      setStatus('Scan a student ID before scanning a snack.', 'bad');
      return;
    }
    state.queue.push({ studentBarcode: student.barcode, snackBarcode: sn.barcode, snackName: sn.name, studentName: student.full_name, requestId: uuid() });
    el('queue-count').textContent = state.queue.length > 1 ? `${state.queue.length} queued` : '';
    setStatus(`Received ${sn.name}. Confirming purchase…`);
    processQueue();
  }
  async function processQueue() {
    if (state.processing) return;
    state.processing = true;
    while (state.queue.length && state.loggedIn) {
      const item = state.queue[0];
      try {
        const { data, error } = await db.rpc('checkout_snack', {
          p_student_barcode: item.studentBarcode,
          p_snack_barcode: item.snackBarcode,
          p_request_id: item.requestId
        });
        if (error) throw error;
        const st = studentByBarcode(item.studentBarcode);
        const sn = snackByBarcode(item.snackBarcode);
        if (st) st.points = data.balance;
        if (sn && data.stock !== undefined) sn.stock = data.stock;
        addFeed(item.snackName, `${item.studentName} • -${sn?.price ?? '?'} points • ${data.balance} left`, true);
        setStatus(`${item.snackName} sold to ${item.studentName}. Balance: ${data.balance} points.`, 'good');
        renderStats(); renderStudentBox(); renderStudents(); renderSnacks();
        // Update history without delaying the next scan.
        if (state.tab === 'activity') refreshHistory().catch(() => {});
      } catch (error) {
        // Do not automatically send a new request with a different ID: that
        // could cause double charges after a network interruption.
        addFeed(item.snackName, `${item.studentName} • ${errText(error)}`, false);
        setStatus(`Not confirmed: ${errText(error)}`, 'bad');
        toast(`Checkout issue: ${errText(error)}`, true);
        // Reload authoritative balances and stock after an uncertain request.
        refreshReferenceData().catch(() => {});
      } finally {
        state.queue.shift();
        el('queue-count').textContent = state.queue.length ? `${state.queue.length} queued` : '';
      }
    }
    state.processing = false;
    focusScanner();
  }
  async function doReload(points) {
    const st = selectedStudent();
    if (!st) { toast('Select a student first.', true); focusScanner(); return; }
    if (!window.confirm(`Confirm that you received $${points} from ${st.full_name}? This adds ${points} points.`)) return;
    const key = 'reload-' + st.id;
    if (state.busyActions.has(key)) return;
    state.busyActions.add(key);
    try {
      const { data, error } = await db.rpc('reload_points', {
        p_student_barcode: st.barcode, p_points: points,
        p_note: `Staff-confirmed $${points} payment`, p_request_id: uuid()
      });
      if (error) throw error;
      st.points = data.balance;
      renderAll();
      setStatus(`${st.full_name} reloaded ${points} points. New balance: ${data.balance}.`, 'good');
      toast(`Added ${points} points to ${st.full_name}.`);
      await refreshHistory();
    } catch (error) { toast(errText(error), true); await refreshReferenceData().catch(() => {}); }
    finally { state.busyActions.delete(key); focusScanner(); }
  }
  async function saveStudent(event) {
    event.preventDefault();
    const barcode = el('student-barcode').value.trim();
    const name = el('student-name').value.trim();
    if (!barcode || !name) return;
    try {
      const { data, error } = await db.rpc('save_student', { p_barcode: barcode, p_full_name: name });
      if (error) throw error;
      updateRow('students', data);
      el('student-form').reset();
      renderAll(); toast(`Saved ${data.full_name}.`);
      el('student-barcode').focus();
    } catch (error) { toast(errText(error), true); }
  }
  async function saveSnack(event) {
    event.preventDefault();
    const barcode = el('snack-barcode').value.trim();
    const name = el('snack-name').value.trim();
    const price = Number(el('snack-price').value);
    const rawStock = el('snack-stock').value.trim();
    const stock = rawStock === '' ? null : Number(rawStock);
    if (!barcode || !name || ![1,2].includes(price) || (stock !== null && (!Number.isInteger(stock) || stock < 0))) {
      toast('Check snack fields before saving.', true); return;
    }
    try {
      const { data, error } = await db.rpc('save_snack', {
        p_barcode: barcode, p_name: name, p_price: price, p_stock: stock
      });
      if (error) throw error;
      updateRow('snacks', data);
      el('snack-form').reset();
      renderAll(); toast(`Saved ${data.name}.`);
      el('snack-barcode').focus();
    } catch (error) { toast(errText(error), true); }
  }
  async function studentTableClick(event) {
    const btn = event.target.closest('button[data-student-action]');
    if (!btn) return;
    const st = state.students.find(x => x.id === Number(btn.dataset.id));
    if (!st) return;
    const action = btn.dataset.studentAction;
    if (action === 'checkout') { selectStudent(st); setTab('checkout'); return; }
    if (action === 'adjust') {
      const raw = window.prompt(`Adjust ${st.full_name}'s balance (${st.points}). Enter signed points, e.g. 3 or -2:`);
      if (raw === null) return;
      const delta = Number(raw);
      if (!Number.isInteger(delta) || !delta || Math.abs(delta) > 10000) { toast('Enter a nonzero whole number.', true); return; }
      const note = window.prompt('Reason for adjustment (saved in history):');
      if (note === null) return;
      if (!note.trim()) { toast('A reason is required for a manual correction.', true); return; }
      if (!window.confirm(`Change ${st.full_name}'s points by ${delta > 0 ? '+' : ''}${delta}?`)) return;
      try {
        const { data, error } = await db.rpc('adjust_points', {
          p_student_barcode: st.barcode, p_delta: delta, p_note: note.trim(), p_request_id: uuid()
        });
        if (error) throw error;
        st.points = data.balance;
        renderAll(); toast(`Balance updated to ${data.balance}.`);
        await refreshHistory();
      } catch (error) { toast(errText(error), true); refreshReferenceData().catch(() => {}); }
      return;
    }
    if (action === 'toggle') {
      if (!window.confirm(`${st.active ? 'Deactivate' : 'Reactivate'} ${st.full_name}?`)) return;
      try {
        const { data, error } = await db.rpc('set_student_active', { p_barcode: st.barcode, p_active: !st.active });
        if (error) throw error;
        updateRow('students', data);
        if (state.selectedStudentBarcode === st.barcode && !data.active) state.selectedStudentBarcode = null;
        renderAll(); toast(`${st.full_name} ${data.active ? 'reactivated' : 'deactivated'}.`);
      } catch (error) { toast(errText(error), true); }
    }
  }
  async function snackTableClick(event) {
    const btn = event.target.closest('button[data-snack-action]');
    if (!btn) return;
    const sn = state.snacks.find(x => x.id === Number(btn.dataset.id));
    if (!sn) return;
    if (btn.dataset.snackAction === 'edit') {
      el('snack-barcode').value = sn.barcode;
      el('snack-name').value = sn.name;
      el('snack-price').value = String(sn.price);
      el('snack-stock').value = sn.stock === null ? '' : String(sn.stock);
      el('snack-barcode').focus();
      window.scrollTo({ top: 0, behavior: 'smooth' });
    } else {
      if (!window.confirm(`${sn.active ? 'Deactivate' : 'Reactivate'} ${sn.name}?`)) return;
      try {
        const { data, error } = await db.rpc('set_snack_active', { p_barcode: sn.barcode, p_active: !sn.active });
        if (error) throw error;
        updateRow('snacks', data);
        renderAll(); toast(`${sn.name} ${data.active ? 'reactivated' : 'deactivated'}.`);
      } catch (error) { toast(errText(error), true); }
    }
  }
  async function refundClick(event) {
    const btn = event.target.closest('button[data-refund-id]');
    if (!btn) return;
    const tx = state.transactions.find(x => x.id === btn.dataset.refundId);
    if (!tx || !window.confirm('Refund this purchase? Points and tracked inventory will be restored.')) return;
    btn.disabled = true;
    try {
      const { error } = await db.rpc('refund_purchase', { p_transaction_id: tx.id, p_request_id: uuid() });
      if (error) throw error;
      await refreshAll();
      toast('Purchase refunded. Points and stock restored.');
    } catch (error) { toast(errText(error), true); btn.disabled = false; }
  }
  function exportCSV() {
    const quote = val => '"' + String(val ?? '').replace(/"/g, '""') + '"';
    const header = ['Date','Transaction ID','Type','Student','Student barcode','Snack','Snack barcode','Points change','Balance after','Note'];
    const rows = state.transactions.map(t => {
      const student = studentById(t.student_id); const snack = snackById(t.snack_id);
      return [t.created_at,t.id,t.kind,student?.full_name,student?.barcode,snack?.name,snack?.barcode,t.delta_points,t.balance_after,t.note];
    });
    const csv = '\uFEFF' + [header, ...rows].map(row => row.map(quote).join(',')).join('\r\n');
    const url = URL.createObjectURL(new Blob([csv], { type: 'text/csv;charset=utf-8;' }));
    const a = document.createElement('a'); a.href = url;
    a.download = `snack-pass-transactions-${new Date().toISOString().slice(0,10)}.csv`;
    document.body.appendChild(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 2000);
  }

  function wireEvents() {
    document.querySelectorAll('[data-tab]').forEach(btn => btn.addEventListener('click', () => setTab(btn.dataset.tab)));
    el('scan').addEventListener('keydown', e => {
      if (e.key === 'Enter') { e.preventDefault(); const code = e.currentTarget.value; e.currentTarget.value = ''; scanBarcode(code); }
    });
    el('clear-student').addEventListener('click', () => { state.selectedStudentBarcode = null; renderStudentBox(); setStatus('Student cleared. Scan the next ID.'); focusScanner(); });
    el('clear-feed').addEventListener('click', () => { state.feed = []; renderFeed(); focusScanner(); });
    el('reload5').addEventListener('click', () => doReload(5));
    el('reload10').addEventListener('click', () => doReload(10));
    el('student-form').addEventListener('submit', saveStudent);
    el('snack-form').addEventListener('submit', saveSnack);
    el('student-search').addEventListener('input', renderStudents);
    el('snack-search').addEventListener('input', renderSnacks);
    el('student-rows').addEventListener('click', studentTableClick);
    el('snack-rows').addEventListener('click', snackTableClick);
    el('activity-kind').addEventListener('change', renderActivity);
    el('activity-rows').addEventListener('click', refundClick);
    el('refresh-activity').addEventListener('click', async () => { try { await refreshAll(); toast('Data refreshed.'); } catch(e) { toast(errText(e), true); } });
    el('csv').addEventListener('click', exportCSV);
    el('login-form').addEventListener('submit', async e => {
      e.preventDefault();
      if (!db) return;
      const btn = el('login-btn'); btn.disabled = true;
      el('auth-message').textContent = '';
      try {
        const { data, error } = await db.auth.signInWithPassword({ email: el('email').value.trim(), password: el('password').value });
        if (error) throw error;
        await start(data.session);
        el('password').value = '';
      } catch (error) { el('auth-message').textContent = errText(error); }
      finally { btn.disabled = false; }
    });
    el('logout').addEventListener('click', async () => { await db.auth.signOut(); stop(); });
    window.addEventListener('online', () => setConnection('Connected'));
    window.addEventListener('offline', () => { setConnection('Offline'); toast('Internet is disconnected. Purchases cannot be confirmed.', true); });
    // Keyboard-only scanning in checkout. The input keeps focus after each scan.
    el('scan').addEventListener('blur', () => {
      // Do not steal focus from buttons/forms; cashier can click to refocus.
    });
    // Periodic sync is a fallback if Supabase Realtime is not enabled.
    setInterval(() => { if (state.loggedIn && !state.processing) refreshReferenceData().catch(() => {}); }, 30000);
  }
  async function init() {
    wireEvents();
    if (!dbReady) {
      el('auth-message').textContent = 'Setup needed: enter your Supabase URL and publishable/anon key in config.js. Read README.md.';
      el('login-btn').disabled = true;
      setConnection('Setup required');
      return;
    }
    db.auth.onAuthStateChange((event, session) => {
      // Defer calls to database from inside the auth callback.
      setTimeout(() => {
        if (event === 'SIGNED_OUT') stop();
        else if (event === 'SIGNED_IN' || event === 'INITIAL_SESSION') start(session);
      }, 0);
    });
    try {
      const { data, error } = await db.auth.getSession();
      if (error) throw error;
      if (data.session) await start(data.session);
    } catch (error) { el('auth-message').textContent = errText(error); }
  }
  init();
})();
