// WhisperFirst landing — ลูป rAF เดียวคุมเอฟเฟกต์ตามการเลื่อน (เขียน CSS custom property ลง element ตรงๆ)
(() => {
  'use strict';

  // ── ปล่อยเวอร์ชันใหม่: แก้ตรงนี้ที่เดียว ──
  const RELEASE = {
    version: '1.0',
    size: '1.5 MB',
    sha256: '587eb6d8f2b1b273fb1dee701fe122ec7beb20344d3bb095e20662fd8ce18fe2',
    url: 'download/WhisperFirst.dmg',
  };

  const WORDS = ['เอ่อ', 'พรุ่งนี้', 'ประชุม', 'ตอน', 'สิบโมง', 'เอ้ย', 'ไม่ใช่', 'สิบโมงครึ่ง', 'นะครับ'];
  const FINAL = 'พรุ่งนี้ประชุมตอน 10 โมงครึ่งนะครับ';
  const RAW = 'เอ่อ พรุ่งนี้ประชุมตอนสิบโมง เอ้ย ไม่ใช่ สิบโมงครึ่ง แล้วก็ แบบว่า ฝากเตรียมสไลด์ด้วยนะครับ อ่า แล้วก็ส่งลิงก์ด็อกเกอร์ให้ทีมด้วย  ·  ';
  const CLEAN = 'พรุ่งนี้ประชุมตอน 10 โมงครึ่ง แล้วก็ฝากเตรียม slide ด้วยนะครับ แล้วก็ส่งลิงก์ Docker ให้ทีมด้วย  ·  ';
  const FILLERS = ['เอ่อ', 'อ่า', 'แบบว่า', 'เอ้ย'];
  const STEPS = [
    { title: 'กดค้าง Option ขวา', key: 'Option ขวา', desc: 'ที่ไหนก็ได้ที่มีเคอร์เซอร์ เกาะดำบนขอบจอขยายออกมาบอกว่ากำลังฟัง' },
    { title: 'พูดตามที่คิด', key: 'พูดเลย', desc: 'เห็นคำที่พูดสดๆ บนเกาะ จะพูดผิด พูดซ้ำ หรือ เอ่อ อ่า ก็ได้ตามสบาย' },
    { title: 'ปล่อย แล้วข้อความก็อยู่ตรงนั้น', key: 'ปล่อยปุ่ม', desc: 'ข้อความที่เกลาแล้ววางลงช่องพิมพ์ของแอปที่ใช้อยู่ในราว 2 วินาที' },
  ];
  // จาก Sources/Core/Styles.swift
  const CATS = [
    { id: 'personal', label: 'แชทส่วนตัว', apps: ['LINE', 'Messenger', 'WhatsApp', 'Messages', 'Telegram', 'Discord'], def: 'casual' },
    { id: 'work', label: 'แชทงาน', apps: ['Slack', 'Microsoft Teams'], def: 'normal' },
    { id: 'email', label: 'อีเมล', apps: ['Mail', 'Outlook'], def: 'formal' },
    { id: 'other', label: 'แอปอื่นๆ', apps: ['Notes', 'Docs', 'Terminal', 'Claude', 'ChatGPT', 'และอื่นๆ'], def: 'normal' },
  ];
  const STYLES = [
    { id: 'formal', title: 'ทางการ', subtitle: 'ใส่เครื่องหมายวรรคตอนครบ + แบ่งย่อหน้า', example: 'สวัสดีครับพี่\n\nพรุ่งนี้สะดวกคุยเรื่อง Dashboard ตอน 10 โมงไหมครับ?\nเดี๋ยวผมส่ง Slide ให้ก่อนนะครับ' },
    { id: 'normal', title: 'ปกติ', subtitle: 'ใส่เครื่องหมายเท่าที่จำเป็น', example: 'สวัสดีครับพี่ พรุ่งนี้สะดวกคุยเรื่อง dashboard ตอน 10 โมงไหมครับ? เดี๋ยวผมส่ง slide ให้ก่อนนะครับ' },
    { id: 'casual', title: 'สบายๆ', subtitle: 'แบบแชท ไม่ใส่เครื่องหมาย', example: 'สวัสดีครับพี่ พรุ่งนี้สะดวกคุยเรื่อง dashboard ตอน 10 โมงไหมครับ เดี๋ยวผมส่ง slide ให้ก่อนนะครับ' },
  ];
  const FAQS = [
    { q: 'ใส่ key แล้วขึ้นว่า key rejected หรือ quota', a: 'key rejected = key ผิดหรือคัดลอกมาไม่ครบ ให้คัดลอกใหม่ทั้งหมดจาก AI Studio แล้ววางใน Settings · quota used up = key ฟรีใช้ครบโควตาแล้ว รอสักครู่แล้วลองใหม่ หรือเปิด billing ใน AI Studio' },
    { q: 'ฟรีไหม', a: 'แอปฟรี · ส่วน Gemini API key ขอได้ฟรีจาก Google AI Studio มีโควตาจำกัดต่อนาทีและต่อวัน ใช้พิมพ์ทั่วไปพอ ถ้าเต็มจะขึ้นเตือนบนเกาะดำ' },
    { q: 'ทำไม Mac เตือนตอนเปิดครั้งแรก', a: 'เพราะแอปนี้ไม่ได้ลงทะเบียนนักพัฒนากับ Apple (ทำแจกเพื่อน) macOS เลยตรวจผู้พัฒนาไม่ได้ กด Open Anyway ใน System Settings → Privacy & Security ครั้งเดียวก็เปิดได้ตลอด (ดูขั้นที่ 2 ในวิธีติดตั้ง)' },
    { q: 'ใช้กับ Mac Intel, Windows หรือ iPhone ได้ไหม', a: 'ตอนนี้ยังไม่ได้ ใช้ได้เฉพาะ Mac ชิป Apple (M1 ขึ้นไป) ที่เป็น macOS 14.2 ขึ้นไป' },
    { q: 'ใช้กับแอปไหนได้บ้าง', a: 'ทุกช่องที่พิมพ์ได้บน Mac — แชท อีเมล เอกสาร เบราว์เซอร์ Terminal หรือ AI chat ถ้าเปลี่ยนแอประหว่างพูด ข้อความจะถูกคัดลอกลง clipboard แทนการวางผิดที่' },
    { q: 'พูดไทยปนอังกฤษได้ไหม', a: 'ได้ ศัพท์อังกฤษจะถูกเขียนเป็นภาษาอังกฤษ เช่น Docker, Dashboard แทนการถอดเป็นตัวไทย และเพิ่มชื่อเฉพาะลงพจนานุกรมให้สะกดถูกทุกครั้งได้' },
    { q: 'ถ้าคำไหนถอดผิด ต้องทำยังไง', a: 'แก้ในช่องพิมพ์ตามปกติ แอปจะดูว่าเป็นคำที่ฟังผิดหรือไม่ แล้วจำไว้ให้เอง หรือเลือกคำแล้วกด Ctrl + Option + D เพื่อเพิ่มลงพจนานุกรมทันที' },
    { q: 'เสียงและข้อความของฉันไปไหน', a: 'เสียงส่งตรงจาก Mac ไป Google Gemini ด้วย key ของคุณ ไม่ผ่านเซิร์ฟเวอร์ของเรา พร้อมบริบทที่ช่วยให้เขียนถูก (ข้อความเกี่ยวกับฉัน คำในพจนานุกรม ชื่อแอป ข้อความก่อนเคอร์เซอร์ไม่เกิน 400 ตัว และวลีที่คุณแก้) — ปิดได้ใน Settings · ประวัติ พจนานุกรม และการตั้งค่าอยู่ในเครื่อง · ถ้าใช้ key แบบฟรี Google อาจนำข้อมูลไปปรับปรุงบริการและอาจมีคนตรวจอ่าน ถ้ากังวลให้เปิด billing ใน AI Studio หรือใช้ Private mode' },
    { q: 'ต้องต่อเน็ตตลอดไหม', a: 'ปกติต้องต่อเน็ต ถ้าอยากใช้แบบออฟไลน์ (Private mode — ขั้นสูง): 1) ติดตั้ง Homebrew แล้วรัน brew install whisper-cpp 2) โหลดโมเดล ggml-large-v3.bin (~3 GB) จาก huggingface.co/ggerganov/whisper.cpp 3) วางไว้ที่ ~/Library/Application Support/WhisperFirst/models/ 4) เปิด Settings → Privacy → Private mode · ช้ากว่าและเกลาน้อยกว่าแบบ cloud และใช้โหมดคำสั่งไม่ได้' },
    { q: 'อัปเดตยังไง', a: 'โหลดไฟล์ใหม่จากหน้านี้ แล้วลากทับของเดิมใน Applications ไม่ต้องให้สิทธิ์ใหม่' },
    { q: 'ใช้คู่กับ Wispr Flow ได้ไหม', a: 'ได้ แต่อย่าตั้งปุ่มลัดซ้ำกัน ไม่งั้นจะทำงานทั้งคู่' },
    { q: 'ใช้ปุ่มข้างของเมาส์ได้ไหม', a: 'ได้ ตั้งในหน้า Shortcuts ของแอป (เช่น Mouse 4 = แฮนด์ฟรี) · ค่าเริ่มต้นไม่ได้ผูกไว้ เพราะปุ่มเหล่านี้คือ Back/Forward ของเบราว์เซอร์' },
    { q: 'อยากใช้ปุ่ม fn / 🌐', a: 'ตั้ง System Settings → Keyboard → “Press 🌐 key to” เป็น Do Nothing ก่อน แล้วไปตั้งปุ่มลัดในหน้า Shortcuts ของแอป (ใช้ปุ่มข้างของเมาส์ได้ด้วย)' },
    { q: 'ถอนการติดตั้งยังไง', a: 'ปิดแอปจาก menu bar → ลบ WhisperFirst ออกจาก Applications → ลบโฟลเดอร์ ~/Library/Application Support/WhisperFirst' },
  ];
  const DIMS = { idle: [128, 32], listening: [440, 82], thinking: [240, 40], done: [300, 40] };

  const $ = (s, el = document) => el.querySelector(s);
  const $$ = (s, el = document) => Array.from(el.querySelectorAll(s));
  const clamp = (v) => Math.max(0, Math.min(1, v));
  const ease = (t) => (t < 0.5 ? 2 * t * t : 1 - Math.pow(-2 * t + 2, 2) / 2);
  const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const ua = navigator.userAgent;
  // iPad รุ่นใหม่รายงานตัวเป็น Macintosh → ใช้จุดสัมผัสแยก
  const isMac = /Macintosh/.test(ua) && navigator.maxTouchPoints < 2;
  if (!isMac) document.documentElement.classList.add('not-mac');

  // ── ปุ่มดาวน์โหลด / เวอร์ชัน ──
  $$('[data-ver]').forEach((el) => (el.textContent = RELEASE.version));
  $$('[data-size]').forEach((el) => (el.textContent = RELEASE.size));
  $$('[data-sha]').forEach((el) => (el.textContent = RELEASE.sha256));
  const pageURL = location.href.split('#')[0];
  async function copyLink(btn) {
    try { await navigator.clipboard.writeText(pageURL); } catch {
      const t = document.createElement('textarea'); t.value = pageURL; document.body.appendChild(t); t.select();
      try { document.execCommand('copy'); } catch {} t.remove();
    }
    if (btn) { const old = btn.textContent; btn.textContent = 'คัดลอกแล้ว ✓'; setTimeout(() => (btn.textContent = old), 1800); }
  }
  $$('[data-copy]').forEach((b) => b.addEventListener('click', () => copyLink(b)));
  $$('[data-dl]').forEach((a) => {
    if (isMac) a.href = RELEASE.url;
    a.addEventListener('click', (e) => {
      if (!isMac) { e.preventDefault(); copyLink($('[data-copy]')); return; }
      // เริ่มโหลดแล้วพาไปขั้นติดตั้ง (ลิงก์ไฟล์ไม่เปลี่ยนหน้า)
      setTimeout(() => $('#install').scrollIntoView({ behavior: reduce ? 'auto' : 'smooth' }), 150);
    });
  });

  // ── แท่งคลื่นเสียง ──
  $$('[data-bars]').forEach((box) => {
    const n = +box.dataset.bars, H = +box.dataset.h;
    box.style.height = H + 'px';
    for (let i = 0; i < n; i++) {
      const s = document.createElement('span');
      s.style.height = H - 2 + 'px';
      s.style.opacity = (0.55 + 0.45 * Math.sin(i * 0.6) ** 2).toFixed(2);
      s.style.animation = `wfbar ${0.7 + (i % 5) * 0.12}s ease-in-out ${((i * 0.07) % 0.6).toFixed(2)}s infinite`;
      box.appendChild(s);
    }
  });

  // ── Ribbon (hero) ──
  const NS = 'http://www.w3.org/2000/svg';
  const tpRaw = $('#tpRaw'), tpClean = $('#tpClean');
  tpRaw.textContent = RAW.repeat(4);
  tpClean.textContent = CLEAN.repeat(4);
  const ri = $('#ribbonIsland');
  for (let i = 0; i < 13; i++) {
    const r = document.createElementNS(NS, 'rect');
    Object.entries({ x: -39 + i * 6.2, y: -12, width: 3, height: 24, rx: 1.5, fill: '#fff', class: 'bar' }).forEach(([k, v]) => r.setAttribute(k, v));
    r.style.animation = `wfbar ${0.6 + (i % 4) * 0.13}s ease-in-out ${((i * 0.09) % 0.5).toFixed(2)}s infinite`;
    ri.appendChild(r);
  }
  const ribbon = $('#ribbon');
  let popId = 0;
  function pop() {
    if (document.hidden || window.scrollY > innerHeight * 0.8) return;
    if (ribbon.querySelectorAll('.pop').length >= 4) return;
    const id = ++popId;
    const el = document.createElement('span');
    el.className = 'pop';
    el.textContent = FILLERS[id % FILLERS.length];
    el.style.setProperty('--dx', (id % 2 ? 1 : -1) * (20 + ((id * 13) % 30)) + 'px');
    el.style.setProperty('--rot', (id % 2 ? 1 : -1) * (8 + ((id * 7) % 12)) + 'deg');
    ribbon.appendChild(el);
    setTimeout(() => el.remove(), 1800);
  }
  if (!reduce) setInterval(pop, 2200);

  // ── How it works ──
  const stepsOl = $('#howSteps');
  STEPS.forEach((st, i) => {
    const li = document.createElement('li');
    li.innerHTML = `<span>0${i + 1}</span><b></b>`;
    li.querySelector('b').textContent = st.title;
    stepsOl.appendChild(li);
  });
  const island = $('#island'), howInput = $('#howInput'), howInputText = $('#howInputText');
  let how = { phase: null, n: -1, step: -1 };
  function setHow(phase, n, step) {
    if (phase === how.phase && n === how.n && step === how.step) return;
    if (phase !== how.phase) {
      island.dataset.phase = phase;
      const [w, h] = DIMS[phase];
      island.style.width = w + 'px';
      island.style.height = h + 'px';
      const done = phase === 'done';
      howInput.classList.toggle('done', done);
      howInputText.textContent = done ? FINAL : 'พิมพ์ข้อความ…';
    }
    if (n !== how.n) {
      const words = WORDS.slice(0, n);
      $('#liveStable').textContent = words.slice(0, -2).join(' ');
      $('#liveTail').textContent = words.slice(-2).join(' ');
      $('#timer').textContent = `0:0${Math.min(9, Math.ceil(n / 2))}`;
    }
    if (step !== how.step) {
      $$('li', stepsOl).forEach((li, i) => li.classList.toggle('on', i === step));
      $('#howTitle').textContent = STEPS[step].title;
      $('#howDesc').textContent = STEPS[step].desc;
      $('#howKey').textContent = STEPS[step].key;
    }
    how = { phase, n, step };
  }

  // ── Writing styles ──
  let cat = 'personal';
  const picks = {};
  function renderStyles() {
    const c = CATS.find((x) => x.id === cat);
    const picked = picks[cat] ?? c.def;
    $('#catTabs').innerHTML = '';
    CATS.forEach((x) => {
      const b = document.createElement('button');
      b.type = 'button'; b.textContent = x.label; b.setAttribute('aria-pressed', String(x.id === cat));
      b.addEventListener('click', () => { cat = x.id; renderStyles(); });
      $('#catTabs').appendChild(b);
    });
    $('#catApps').innerHTML = '<small>ใช้ใน</small>';
    c.apps.forEach((a) => { const s = document.createElement('span'); s.textContent = a; $('#catApps').appendChild(s); });
    $('#styleCards').innerHTML = '';
    STYLES.forEach((st) => {
      const on = st.id === picked;
      const b = document.createElement('button');
      b.type = 'button'; b.className = 'style-card'; b.setAttribute('role', 'radio'); b.setAttribute('aria-checked', String(on));
      b.innerHTML = '<span class="t"><b></b><i></i></span><span class="sub"></span><span class="ex-l">ตัวอย่าง</span><span class="ex"></span>';
      b.querySelector('.t b').textContent = st.title;
      b.querySelector('.t i').textContent = on ? '✓' : '';
      b.querySelector('.sub').textContent = st.subtitle;
      b.querySelector('.ex').textContent = st.example;
      b.addEventListener('click', () => { picks[cat] = st.id; renderStyles(); });
      $('#styleCards').appendChild(b);
    });
  }
  renderStyles();

  // ── FAQ (เปิดทีละข้อ) ──
  const faqList = $('#faqList');
  FAQS.forEach((f, i) => {
    const item = document.createElement('div');
    item.className = 'faq-item';
    item.innerHTML = `<button type="button" aria-expanded="false" aria-controls="faq${i}"><span></span><span aria-hidden="true">+</span></button><p class="a" id="faq${i}" hidden></p>`;
    item.querySelector('button span').textContent = f.q;
    item.querySelector('.a').textContent = f.a;
    faqList.appendChild(item);
  });
  function openFaq(idx) {
    $$('.faq-item', faqList).forEach((it, i) => {
      const on = i === idx;
      it.querySelector('button').setAttribute('aria-expanded', String(on));
      it.querySelector('button span:last-child').textContent = on ? '−' : '+';
      it.querySelector('.a').hidden = !on;
    });
  }
  let faqOpen = 0;
  openFaq(0);
  $$('.faq-item button', faqList).forEach((b, i) => b.addEventListener('click', () => { faqOpen = faqOpen === i ? -1 : i; openFaq(faqOpen); }));

  // ── ลูปหลัก ──
  const hero = $('#top'), cover = $('#cover');
  const speed = $('#speed'), speedStage = $('#speedStage'), counter = $('#counter');
  const howSec = $('#how'), howStage = $('#howStage');
  const reveals = $$('.reveal');
  let off = 0, lastY = window.scrollY, lastT = 0;

  function pinned(sec) {
    const r = sec.getBoundingClientRect();
    return clamp(-r.top / (r.height - innerHeight));
  }

  function frame(t) {
    const vh = innerHeight, y = window.scrollY;
    const dt = lastT ? Math.min(64, t - lastT) : 16; lastT = t;
    const dy = y - lastY; lastY = y;

    if (!reduce) {
      off += dt * 0.045 + Math.abs(dy) * 0.6;
      [tpRaw, tpClean].forEach((tp) => {
        if (!tp._unit) { try { tp._unit = tp.getComputedTextLength() / 4; } catch {} }
        const u = tp._unit || 900;
        tp.setAttribute('startOffset', String((off % u) - u));
      });
      hero.style.setProperty('--c', clamp(1 - cover.getBoundingClientRect().top / vh).toFixed(3));
      reveals.forEach((el) => {
        el.style.setProperty('--r', ease(clamp((vh - el.getBoundingClientRect().top) / (vh * (+el.dataset.span || 0.55)))).toFixed(3));
      });
    }

    // speed: reduce motion → แสดงสถานะสุดท้าย
    const p = reduce ? 1 : pinned(speed);
    const k = clamp(p / 0.55);
    speedStage.style.setProperty('--g', ease(k).toFixed(4));
    speedStage.style.setProperty('--k', k.toFixed(4));
    speedStage.style.setProperty('--k2', clamp((k - 0.45) / 0.1).toFixed(3));
    speedStage.style.setProperty('--k3', clamp((k - 0.95) / 0.05).toFixed(3));
    speedStage.style.setProperty('--s', clamp((p - 0.5) / 0.2).toFixed(3));
    speedStage.style.setProperty('--t', clamp((p - 0.68) / 0.2).toFixed(3));
    counter.textContent = (2 * k).toFixed(1);

    const hp = reduce ? 1 : pinned(howSec);
    howStage.style.setProperty('--p', hp.toFixed(4));
    if (hp < 0.16) setHow('idle', 0, 0);
    else if (hp < 0.62) setHow('listening', Math.min(WORDS.length, Math.ceil(((hp - 0.18) / 0.4) * WORDS.length)), hp < 0.24 ? 0 : 1);
    else if (hp < 0.74) setHow('thinking', WORDS.length, 2);
    else setHow('done', WORDS.length, 2);
  }

  if (reduce) {
    // ไม่มีลูปต่อเนื่อง: คำนวณครั้งเดียว + ตอนเลื่อน (pinned section อยู่ที่สถานะสุดท้ายเสมอ)
    frame(0);
  } else {
    const loop = (t) => { frame(t); requestAnimationFrame(loop); };
    requestAnimationFrame(loop);
  }
})();
