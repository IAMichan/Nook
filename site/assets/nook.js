/* Shared behaviour for every page of the Nook site. */
const $=s=>document.querySelector(s),$$=s=>[...document.querySelectorAll(s)];

/* Run a demo once its element scrolls into view. */
function whenVisible(el,fn,threshold=.3){if(!el)return;let done=false;
  new IntersectionObserver((e,o)=>{if(e[0].isIntersecting&&!done){done=true;fn();o.disconnect()}},{threshold}).observe(el)}

/* Reveal on scroll, and count up numbers marked data-n. */
(function(){
  const io=new IntersectionObserver(es=>es.forEach(e=>{if(!e.isIntersecting)return;e.target.classList.add('in');
    e.target.querySelectorAll('[data-n]').forEach(c=>{let v=0;const to=+c.dataset.n,s=setInterval(()=>{c.textContent=++v;if(v>=to)clearInterval(s)},60)});
    io.unobserve(e.target)}),{threshold:.12});
  $$('.rv').forEach(el=>io.observe(el));
})();

/* Current page in the nav, and the mobile menu. */
(function(){
  const page=(location.pathname.split('/').pop()||'index.html');
  $$('nav .links a').forEach(a=>{if(a.getAttribute('href')===page)a.classList.add('on')});
  const b=$('.menu-btn');if(b)b.onclick=()=>$('nav').classList.toggle('open');
})();

/* Copy buttons on code blocks. */
$$('.copybtn').forEach(b=>b.onclick=()=>{const t=b.dataset.copy||b.parentElement.innerText.replace(/^Copy\s*/,'');
  navigator.clipboard?.writeText(t);const o=b.textContent;b.textContent='Copied';setTimeout(()=>b.textContent=o,1400)});

/* Nook's eyes follow the pointer. */
addEventListener('mousemove',e=>{$$('.mascot i').forEach(i=>{const r=i.parentElement.getBoundingClientRect();if(!r.width||r.bottom<0||r.top>innerHeight)return;
  const dx=e.clientX-(r.left+r.width/2),dy=e.clientY-(r.top+r.height/2),d=Math.hypot(dx,dy)||1,m=r.width*.08;i.style.transform=`translate(${dx/d*m}px,${dy/d*m}px)`})});

/* Download buttons point at the newest regular release (betas are skipped): a link marked data-latest-asset gets that
   release's file whose name ends with the given suffix, and data-latest-version shows its version. Without the API
   (offline, rate limited) the link keeps its fallback, the newest release page on GitHub. */
(function(){
  const links=$$('[data-latest-asset]'),labels=$$('[data-latest-version]');if(!links.length&&!labels.length)return;
  fetch('https://api.github.com/repos/IAMichan/nook/releases/latest',{headers:{Accept:'application/vnd.github+json'}})
    .then(r=>r.ok?r.json():Promise.reject(r.status))
    .then(rel=>{
      links.forEach(a=>{const f=(rel.assets||[]).find(x=>x.name.endsWith(a.dataset.latestAsset));if(f)a.href=f.browser_download_url});
      labels.forEach(l=>l.textContent=(rel.name||rel.tag_name));
    }).catch(()=>{});
})();
