"use strict";
const players = ["球员 A", "球员 B", "球员 C"];
const frameNames = ["前一帧", "中间帧", "后一帧"];
const clips = Array.from({length:15}, (_, i) => ({id:i+1, time:13+i*27, frame:1, player:null, state:"pending", close:i%4!==3}));
let activeId=1, filter="all", addTarget=null, fit=true, width=1440, toastTimer;
const history=[];
const $ = id => document.getElementById(id);
const icon = name => '<svg class="icon" aria-hidden="true"><use href="#i-'+name+'"/></svg>';
const esc = value => String(value).replace(/[&<>"']/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
const time = seconds => String(Math.floor(seconds/60)).padStart(2,"0")+":"+String(seconds%60).padStart(2,"0");
function placeholder(clip) {
  const sway=(clip.frame-1)*8, shift=clip.close ? 0 : -20;
  const body=clip.id%3===0 ? "#b9c5d5" : clip.id%3===1 ? "#8795a9" : "#a8b6c7";
  return '<svg class="scene" viewBox="0 0 240 320" role="img" aria-label="投篮姿态占位图，'+frameNames[clip.frame]+'">'+
  '<defs><linearGradient id="bg'+clip.id+'" x2="0" y2="1"><stop stop-color="#263648"/><stop offset="1" stop-color="#142130"/></linearGradient></defs>'+
  '<rect width="240" height="320" fill="url(#bg'+clip.id+')"/><path d="M0 82H240M0 160H240M80 0V160M160 0V160" stroke="#506174" stroke-opacity=".18"/>'+
  '<path d="M0 258L240 229V320H0Z" fill="#333a43"/><path d="M0 288L240 252M63 320L118 245" stroke="#657082" stroke-opacity=".35" fill="none"/>'+
  '<g transform="translate('+shift+' 0)"><ellipse cx="125" cy="294" rx="46" ry="7" fill="#000" opacity=".22"/>'+
  '<circle cx="122" cy="127" r="17" fill="'+body+'"/><path d="M104 147Q122 141 141 148L151 217H98Z" fill="'+body+'"/>'+
  '<path d="M107 158L'+(92+sway)+' 130L'+(109+sway)+' 88M136 159L'+(143+sway)+' 121L'+(126+sway)+' 89" stroke="'+body+'" stroke-width="12" fill="none" stroke-linecap="round" stroke-linejoin="round"/>'+
  '<path d="M109 213L102 249L88 286M139 213L147 249L161 286" stroke="'+body+'" stroke-width="14" fill="none" stroke-linecap="round"/>'+
  '<path d="M80 290h23M153 290h24" stroke="#d5dce5" stroke-width="8" stroke-linecap="round"/>'+
  '<circle cx="'+(119+sway)+'" cy="'+(clip.frame===2 ? 59 : 79)+'" r="13" fill="#c08054" stroke="#e2ad78" stroke-opacity=".55"/>'+
  '<path d="M55 52H43V66M188 52H200V66M43 280V293H55M188 293H200V280" fill="none" stroke="#6aa8ff" stroke-width="2" stroke-opacity=".8"/></g></svg>';
}
function renderCards(focusKey) {
  const shown=clips.filter(c => filter==="all" || (filter==="pending" ? c.state==="pending" : c.state==="uncertain"));
  $("cards").innerHTML=shown.length ? shown.map(c => {
    const status=c.state==="confirmed" ? "已保存" : c.state==="uncertain" ? "需核实" : "待标注";
    return '<article class="card '+(c.id===activeId?"active":"")+'" data-id="'+c.id+'">'+
      '<div class="card-head"><span class="card-title">#'+c.id+' <span class="muted">'+time(c.time)+'</span></span><span class="card-state '+(c.state==="confirmed"?"saved":"")+'">'+status+'</span></div>'+
      '<div class="photo">'+placeholder(c)+'<span class="photo-badge">'+(c.close?"出手区域 · 放大占位":"全景画面 · 占位")+'</span><span class="photo-number">'+(c.frame+1)+' / 3</span><span class="placeholder-caption">'+frameNames[c.frame]+' · 图片占位</span></div>'+
      '<div class="frame-picker" role="group" aria-label="第 '+c.id+' 球的候选帧">'+frameNames.map((n,i)=>'<button data-frame="'+i+'" data-key="frame-'+c.id+'-'+i+'" aria-pressed="'+(i===c.frame)+'">'+n+'</button>').join("")+'</div>'+
      '<div class="player-heading"><span class="player-label">'+(c.player ? '射手：'+esc(c.player) : '点击名字保存射手')+'</span><button class="add-player" data-add="'+c.id+'" data-key="add-'+c.id+'">'+icon("add")+'添加球员</button></div>'+
      '<div class="roster">'+players.map((n,i)=>'<button class="name-button" data-player="'+i+'" data-key="name-'+c.id+'-'+i+'" aria-pressed="'+(c.player===n)+'">'+esc(n)+'</button>').join("")+'</div>'+
      '<div class="card-bottom"><button data-uncertain="'+c.id+'" data-key="uncertain-'+c.id+'">不确定</button><button data-clear="'+c.id+'" data-key="clear-'+c.id+'">清除</button><button class="with-icon" data-watch="'+c.id+'">'+icon("video")+'看视频</button></div>'+
    '</article>';
  }).join("") : '<div class="empty">当前筛选下没有片段</div>';
  $("count").textContent="已标 "+clips.filter(c=>c.state==="confirmed").length+" / "+clips.length;
  $("undo").disabled=!history.length;
  if(focusKey) document.querySelector('[data-key="'+focusKey+'"]')?.focus({preventScroll:true});
}
function announce(message){$("toast").textContent=message;$("toast").hidden=false;clearTimeout(toastTimer);toastTimer=setTimeout(()=>{$("toast").hidden=true;},2200);}
function save(clip, player, state, focusKey){history.push({id:clip.id,player:clip.player,state:clip.state,frame:clip.frame});clip.player=player;clip.state=state;activeId=clip.id;renderCards(focusKey);announce(player?"第 "+clip.id+" 球已标记为 "+player+"（占位演示）":"第 "+clip.id+" 球已更新（占位演示）");}
function openPlayer(target){addTarget=target;$("player-name").value="";$("dialog-error").textContent="";$("player-dialog").showModal();$("player-name").focus();}
$("cards").addEventListener("click", event=>{
  const card=event.target.closest(".card");if(!card)return;const c=clips.find(c=>c.id===Number(card.dataset.id));activeId=c.id;
  const button=event.target.closest("button");
  if(!button){renderCards();return;}
  if(button.hasAttribute("data-frame")){c.frame=Number(button.dataset.frame);renderCards(button.dataset.key);}
  else if(button.hasAttribute("data-add"))openPlayer(c.id);
  else if(button.hasAttribute("data-player"))save(c,players[Number(button.dataset.player)],"confirmed",button.dataset.key);
  else if(button.hasAttribute("data-uncertain"))save(c,null,"uncertain",button.dataset.key);
  else if(button.hasAttribute("data-clear"))save(c,null,"pending",button.dataset.key);
  else if(button.hasAttribute("data-watch"))announce("此处会回到第 "+c.id+" 球的视频审核；当前为布局占位预览");
});
document.querySelectorAll("[data-filter]").forEach(b=>b.addEventListener("click",()=>{filter=b.dataset.filter;document.querySelectorAll("[data-filter]").forEach(x=>x.setAttribute("aria-pressed",String(x===b)));renderCards();}));
$("add-roster").addEventListener("click",()=>openPlayer(null));
$("cancel-player").addEventListener("click",()=>$("player-dialog").close());
$("player-form").addEventListener("submit",event=>{
  event.preventDefault();const name=$("player-name").value.trim();if(!name)return;
  if(players.includes(name)){$("dialog-error").textContent="已存在同名球员，请使用其他名字。";return;}
  players.push(name);const target=addTarget;$("player-dialog").close();
  if(target!==null)save(clips.find(c=>c.id===target),name,"confirmed","add-"+target);else{renderCards();announce("已添加球员（占位演示）");}
});
$("undo").addEventListener("click",()=>{const prior=history.pop();if(!prior)return;Object.assign(clips.find(c=>c.id===prior.id),prior);activeId=prior.id;renderCards();announce("已撤销上一条标注（占位演示）");});
function showModule(shooter){$("quick-page").hidden=!shooter;$("goal-page").hidden=shooter;$("tab-shooter").setAttribute("aria-selected",String(shooter));$("tab-goals").setAttribute("aria-selected",String(!shooter));}
$("tab-shooter").addEventListener("click",()=>showModule(true));$("tab-goals").addEventListener("click",()=>showModule(false));
document.querySelectorAll(".demo-action").forEach(b=>b.addEventListener("click",()=>announce("此控件仅作布局示意")));
document.addEventListener("keydown",event=>{if($("player-dialog").open || /INPUT|SELECT|TEXTAREA/.test(event.target.tagName) || $("quick-page").hidden)return;const i=Number(event.key)-1;if(i>=0&&i<players.length&&i<9&&event.key.length===1){event.preventDefault();const c=clips.find(c=>c.id===activeId);save(c,players[i],"confirmed");}});
function fitPreview(){const scale=fit?Math.min(1,(window.innerWidth-32)/width):1;$("app").style.width=width+"px";$("app").style.transform="scale("+scale+")";$("stage-wrap").style.width=width*scale+"px";$("stage-wrap").style.height=930*scale+"px";}
$("preview-width").addEventListener("change",event=>{width=Number(event.target.value);fitPreview();});
$("fit-toggle").addEventListener("click",()=>{fit=!fit;$("fit-toggle").textContent=fit?"适应窗口":"100% 原始尺寸";$("fit-toggle").setAttribute("aria-pressed",String(fit));fitPreview();});
window.addEventListener("resize",fitPreview);
$("goal-items").innerHTML=clips.slice(0,8).map(c=>'<div class="goal-item"><div class="goal-thumb"></div><div>#'+c.id+' · '+time(c.time)+'<br><small>候选片段占位</small></div></div>').join("");
showModule(new URLSearchParams(location.search).get("view")!=="goals");renderCards();fitPreview();
