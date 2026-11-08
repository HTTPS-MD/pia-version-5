const { chromium } = require('playwright'); const path=require('path'),http=require('http'),fs=require('fs');
const root=process.argv[2],out=process.argv[3];
const mime={'.html':'text/html','.js':'text/javascript','.css':'text/css','.webp':'image/webp','.png':'image/png','.svg':'image/svg+xml','.jpg':'image/jpeg','.mp4':'video/mp4'};
const srv=http.createServer((q,r)=>{const f=path.join(root,decodeURIComponent(q.url.split('?')[0]).replace(/\/$/,'/index.html'));fs.readFile(f,(e,d)=>{if(e){r.writeHead(404).end();return;}r.setHeader('Content-Type',mime[path.extname(f)]||'application/octet-stream');r.end(d);});});
const sig = () => {
  const q = s => [...document.querySelectorAll(s)];
  const nav = document.querySelector('#nav');
  return {
    scrollY: Math.round(scrollY),
    nav: nav ? nav.className : null,
    navAuthInert: q('.nav-auth').map(b => b.inert + '/' + b.getAttribute('aria-hidden')).join(','),
    reveal: q('[data-reveal]').map(e => (e.classList.contains('is-in') ? 'i' : '-') + (e.classList.contains('is-done') ? 'd' : '-')).join(''),
    lit: q('.scrub-w').map(e => e.classList.contains('is-lit') ? '1' : '0').join(''),
    rise: (document.querySelector('.foot-card') || {style:{getPropertyValue:()=>''}}).style.getPropertyValue('--rise'),
    burst: (document.querySelector('#privacy') || {style:{getPropertyValue:()=>''}}).style.getPropertyValue('--burst'),
    spy: q('.nav-link[aria-current]').map(a => a.getAttribute('href')).join(','),
    theme: document.documentElement.getAttribute('data-theme'),
    toggles: q('[data-theme-toggle]').map(t => t.getAttribute('aria-pressed') + '|' + (t.getAttribute('aria-label') || '')).join(','),
    welcome: (document.querySelector('.welcome-text') || {}).textContent,
    welcomeCls: (document.querySelector('#welcome') || {}).className,
    tabs: q('[role=tab]').map(t => t.getAttribute('aria-selected') + (document.activeElement === t ? '*' : '')).join(','),
    panels: q('[role=tabpanel]').map(p => p.hidden ? 'h' : 'v').join(''),
    figures: q('.stage-figure').map(p => p.hidden ? 'h' : 'v').join(''),
    locked: document.body.classList.contains('is-locked'),
    burger: (document.querySelector('#nav-burger') || {getAttribute:()=>null}).getAttribute('aria-expanded'),
    wire: (document.querySelector('#wire') || {}).hidden + '|' + ((document.querySelector('#wire') || {}).className),
    howCls: (document.querySelector('#how-video') ? document.querySelector('#how-video').parentNode.className : ''),
    heroToggle: (document.querySelector('#hero-video-toggle') || {}).className + '|' + ((document.querySelector('#hero-video-toggle') || {}).hidden),
    focus: document.activeElement ? (document.activeElement.id || document.activeElement.tagName) : ''
  };
};
(async()=>{await new Promise(r=>srv.listen(0,'127.0.0.1',r));const o='http://127.0.0.1:'+srv.address().port;
const b=await chromium.launch({headless:true,executablePath:process.env.PIA_CHROME});const log=[];
for(const cfg of [{name:'desktop',w:1280,h:800,motion:'no-preference'},{name:'desktop-reduced',w:1280,h:800,motion:'reduce'},{name:'mobile',w:390,h:844,motion:'no-preference'}]){
 const ctx=await b.newContext({viewport:{width:cfg.w,height:cfg.h},reducedMotion:cfg.motion,isMobile:cfg.name==='mobile'});
 await ctx.route('**/*',r=>r.request().url().startsWith(o)?r.continue():r.abort());
 const p=await ctx.newPage();const errs=[];p.on('pageerror',e=>errs.push(e.message));
 await p.goto(o+'/');await p.waitForTimeout(2500);
 const take=async label=>{await p.waitForTimeout(900);log.push({cfg:cfg.name,label,...await p.evaluate(sig)});};
 await take('top');
 const height=await p.evaluate(()=>document.documentElement.scrollHeight);
 for(const y of [500,1200,2200,3500,5000,Math.max(0,height-cfg.h)]){await p.evaluate(y=>window.scrollTo(0,y),y);await take('scroll'+y);}
 await p.evaluate(()=>window.scrollTo(0,0));await take('back-top');
 // theme toggle
 await p.evaluate(()=>{const t=document.querySelector('[data-theme-toggle]');if(t)t.click();});await take('theme-toggled');
 // tutor picker: click each tab, then keyboard
 await p.evaluate(()=>document.querySelector('#agent-select').scrollIntoView());await take('picker');
 const tabCount=await p.evaluate(()=>document.querySelectorAll('[role=tab]').length);
 for(let i=0;i<tabCount;i++){await p.evaluate(i=>document.querySelectorAll('[role=tab]')[i].click(),i);await take('tab'+i);}
 await p.evaluate(()=>document.querySelectorAll('[role=tab]')[0].focus());
 for(const k of ['ArrowRight','ArrowRight','End','Home','ArrowLeft']){await p.keyboard.press(k);await take('key-'+k);}
 // mobile menu
 if(cfg.name==='mobile'){await p.evaluate(()=>window.scrollTo(0,0));await p.evaluate(()=>document.querySelector('#nav-burger').click());await take('menu-open');await p.keyboard.press('Escape');await take('menu-escape');
   await p.evaluate(()=>document.querySelector('#nav-burger').click());await take('menu-open2');await p.evaluate(()=>document.querySelector('#nav-scrim')&&document.querySelector('#nav-scrim').click());await take('menu-scrim');}
 // offline banner
 await ctx.setOffline(true);await p.evaluate(()=>window.dispatchEvent(new Event('offline')));await take('offline');await ctx.setOffline(false);await p.evaluate(()=>window.dispatchEvent(new Event('online')));await take('online');
 log.push({cfg:cfg.name,label:'errors',errs});await ctx.close();}
fs.writeFileSync(out,JSON.stringify(log,null,1));console.log('captured',log.length,'snapshots');await b.close();srv.close();})();
