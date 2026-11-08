const { chromium } = require('playwright'); const path=require('path'),http=require('http'),fs=require('fs');
const root=process.argv[2],out=process.argv[3];
const mime={'.html':'text/html','.js':'text/javascript','.css':'text/css','.webp':'image/webp','.png':'image/png','.svg':'image/svg+xml','.jpg':'image/jpeg','.mp4':'video/mp4'};
const srv=http.createServer((q,r)=>{const f=path.join(root,decodeURIComponent(q.url.split('?')[0]).replace(/\/$/,'/index.html'));fs.readFile(f,(e,d)=>{if(e){r.writeHead(404).end();return;}r.setHeader('Content-Type',mime[path.extname(f)]||'application/octet-stream');r.end(d);});});
const sig=()=>{const q=s=>[...document.querySelectorAll(s)];const t=s=>{const e=document.querySelector(s);return e?e.textContent.trim().slice(0,160):null;};
 return{
  open:q('.overlay').filter(o=>o.classList.contains('is-open')||o.classList.contains('is-mounted')).map(o=>o.id+':'+o.className.replace(/\s+/g,'.')).join(','),
  locked:document.body.classList.contains('is-locked'),
  inertBg:q('body > *').filter(e=>e.inert).length,
  focus:document.activeElement?(document.activeElement.id||document.activeElement.tagName+'.'+document.activeElement.className.slice(0,20)):'',
  staffStatus:t('#staff-status'),staffMsgs:q('#modal-staff .field-msg').map(e=>e.textContent.trim()).join('|'),
  stSubmit:(document.querySelector('#st-submit')||{}).disabled+'/'+t('#st-submit'),
  invalid:q('[aria-invalid="true"]').map(e=>e.id).join(','),
  joinStep:q('#modal-signin [id^=join-step]').map(e=>e.id+(e.hidden?'h':'v')).join(','),
  joinMsg:t('#join-number-msg'),
  heroMsg:t('#hero-join-msg')||t('.hero-join .field-msg'),
  heroDisabled:(document.querySelector('#hero-join button[type=submit], #hero-join .btn')||{}).disabled,
  acMsgs:q('#modal-activate .field-msg, #modal-activate [id$=-status]').map(e=>e.textContent.trim()).join('|'),
  fpMsgs:q('#modal-forgot .field-msg, #modal-forgot [id$=-status]').map(e=>e.textContent.trim()).join('|'),
  fpCooldown:t('#fp-cooldown'),
  joinErr:t('#join-error-text'),
  toasts:q('#toast-stack > *').map(e=>e.textContent.trim().slice(0,80)).join('|'),
  pwType:q('input[type=password],input[data-pw]').map(i=>i.id+':'+i.type).join(','),
  hash:location.hash,url:location.pathname
 };};
(async()=>{await new Promise(r=>srv.listen(0,'127.0.0.1',r));const o='http://127.0.0.1:'+srv.address().port;
const b=await chromium.launch({headless:true,executablePath:process.env.PIA_CHROME});const log=[];
for(const w of [1280,390]){
 const ctx=await b.newContext({viewport:{width:w,height:800},reducedMotion:'no-preference',isMobile:w<500});
 await ctx.route('**/*',r=>r.request().url().startsWith(o)?r.continue():r.abort());
 const p=await ctx.newPage();const errs=[];p.on('pageerror',e=>errs.push(e.message));
 await p.goto(o+'/');await p.waitForTimeout(1800);
 const take=async label=>{await p.waitForTimeout(450);log.push({w,label,...await p.evaluate(sig)});};
 await take('initial');
 // hero join: invalid then valid-looking number
 const hero=await p.$('#hero-join');
 if(hero){await p.fill('#hero-join input','123');await p.keyboard.press('Enter');await take('hero-short');await p.fill('#hero-join input','20231230142');await p.keyboard.press('Enter');await p.waitForTimeout(900);await take('hero-11-digits');}
 // staff sign in
 await p.evaluate(()=>document.querySelector('[data-auth-open="staff"]').click());await take('staff-open');
 await p.click('#st-submit');await take('staff-empty-submit');
 await p.fill('#st-email','not-an-email');await p.fill('#st-password','x');await p.click('#st-submit');await take('staff-bad-email');
 await p.fill('#st-email','someone@example.test');await p.fill('#st-password','wrongpass1');await p.click('#st-submit');await p.waitForTimeout(1200);await take('staff-network-fail');
 await p.keyboard.press('Escape');await take('staff-escape');
 // student sign-in modal
 await p.evaluate(()=>document.querySelector('[data-auth-open="signin"]').click());await take('signin-open');
 const num=await p.$('#join-number');if(num){await p.fill('#join-number','12');await p.keyboard.press('Enter');await take('join-short');await p.fill('#join-number','20231230142');await p.keyboard.press('Enter');await p.waitForTimeout(1200);await take('join-11-digits');}
 await p.keyboard.press('Escape');await take('signin-escape');
 // forgot password
 await p.evaluate(()=>document.querySelector('[data-auth-open="forgot"]').click());await take('forgot-open');
 await p.click('#fp-submit');await take('forgot-empty');
 await p.fill('#fp-email','bad');await p.click('#fp-submit');await take('forgot-bad');
 await p.fill('#fp-email','someone@example.test');await p.click('#fp-submit');await p.waitForTimeout(1200);await take('forgot-network');
 await p.keyboard.press('Escape');await take('forgot-escape');
 // activate (if reachable)
 const act=await p.evaluate(()=>!!document.querySelector('#modal-activate'));
 if(act){await p.evaluate(()=>{const e=document.querySelector('[data-auth-open="activate"]');if(e)e.click();else if(window.PIAAuthDebug)0;});await take('activate-attempt');}
 // password show toggle
 await p.evaluate(()=>document.querySelector('[data-auth-open="staff"]').click());await p.waitForTimeout(300);
 const toggle=await p.$('#modal-staff .pw-show input, #modal-staff [data-pw-toggle]');if(toggle){await toggle.click();await take('pw-shown');}
 // backdrop click closes
 await p.mouse.click(5,5);await take('backdrop-click');
 log.push({w,label:'errors',errs});await ctx.close();}
fs.writeFileSync(out,JSON.stringify(log,null,1));console.log('captured',log.length);await b.close();srv.close();})();
