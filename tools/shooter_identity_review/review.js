'use strict';
let state, busy=false, activeRef='a', renameId=null, returnFocus=null;
const choices=new Map(), drafts=new Map();
const $=id=>document.getElementById(id);
const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const name=id=>state.players.find(p=>p.id===id)?.name??'未知';
const media=id=>'/media/'+encodeURIComponent(id);
const time=ms=>`${Math.floor(ms/60000)}:${((ms/1000)%60).toFixed(2).padStart(5,'0')}`;
const prediction=r=>state.run?.results[r.id];
const currentReview=r=>state.reviews[r.id]?.run_id===state.run_id?state.reviews[r.id]:null;
function pick(r){
  const value=choices.get(r.id)??{}, saved=currentReview(r);
  const trackId=value.trackId!==undefined?value.trackId:(saved?.status==='named'?saved.track_id:r.selected_track_id);
  const track=r.tracks.find(t=>t.id===trackId);
  const sid=track?(value.sid&&track.sample_ids.includes(value.sid)?value.sid:track.sample_ids[0]):null;
  return {trackId,track,sid,sample:state.samples[sid]};
}
function message(text,error=false){$('message').className=error?'error':'notice';$('message').textContent=text;}
async function load(){try{const r=await fetch('/api/state');if(!r.ok)throw Error('无法读取审核数据');state=await r.json();render();}catch(e){message(e.message,true);}}
async function act(payload,text='已保存到本地'){
  if(busy)return false;busy=true;document.body.setAttribute('aria-busy','true');
  try{const r=await fetch('/api/action',{method:'POST',headers:{'Content-Type':'application/json','X-BHE-Review':'1'},body:JSON.stringify({...payload,revision:state.revision})});const data=await r.json();if(!r.ok)throw Error(data.error||'保存失败');state=data;render();message(text);return true;}
  catch(e){message(e.message+'。未保存的修改仍在当前卡片中。',true);return false;}
  finally{busy=false;document.body.removeAttribute('aria-busy');}
}
function playerOptions(selected,blank=false){return (blank?'<option value="">请选择名字</option>':'')+state.players.map(p=>`<option value="${esc(p.id)}" ${p.id===selected?'selected':''}>${esc(p.name)}</option>`).join('');}
function visible(){return state.rows.filter(r=>{
  const p=prediction(r), review=currentReview(r), f=$('filter').value;
  return (!$('video').value||r.video_id===$('video').value)&&(!$('playerFilter').value||p?.player_id===$('playerFilter').value)&&
    (f==='all'||f==='pending'&&!review&&p?.status!=='reference'||f==='reviewed'&&review||f==='suggested'&&p?.status==='suggested'||f==='unknown'&&p?.status==='unknown'||f==='reference'&&p?.status==='reference');
});}
function render(){
  const focus=document.activeElement, focusKey=focus?.dataset?.focus, pos=window.scrollY;
  $('players').innerHTML=state.players.map(p=>{
    const refs=state.references.filter(r=>r.player_id===p.id), shots={size:state.reference_counts[p.id]??0};
    return `<div class="player"><div class="playerHead"><b>${esc(p.name)}</b><span class="badge">${shots.size} 次参考出手</span><button data-op="rename" data-player="${esc(p.id)}">改名</button></div><div class="refs">${refs.map(ref=>{const s=state.samples[ref.sample_id];return `<div class="ref"><img src="${media(s.image)}" alt="${esc(p.name)}的人工参考图"><button data-op="removeRef" data-sample="${esc(s.id)}" aria-label="移除${esc(p.name)}的此张参考图">移除</button></div>`;}).join('')||'<span class="muted fine">从下方卡片选择清楚的人物参考图</span>'}</div></div>`;
  }).join('');
  $('refPlayer').innerHTML=playerOptions(activeRef);$('refPlayer').value=activeRef;
  const old=$('playerFilter').value;$('playerFilter').innerHTML='<option value="">全部</option>'+playerOptions(old);
  if(!state.players.some(p=>p.id===old))$('playerFilter').value='';
  const prior=$('video').value, videos=[...new Map(state.rows.map(r=>[r.video_id,r.video_name])).entries()];
  $('video').innerHTML='<option value="">全部四节</option>'+videos.map(([id,n])=>`<option value="${esc(id)}">${esc(n)}</option>`).join('');$('video').value=prior;
  const ready=state.players.length>=2&&state.players.every(p=>(state.reference_counts[p.id]??0)>=2);
  $('associate').disabled=!ready;$('galleryHint').textContent=ready?'参考图已就绪，建议每人覆盖不同角度':'每人至少需要两次不同出手的参考图';$('stale').hidden=!state.stale;$('undo').disabled=!state.undo.length;
  const results=Object.values(state.run?.results??{}), suggested=results.filter(r=>r.status==='suggested').length, refs=results.filter(r=>r.status==='reference').length;
  const metrics=state.metrics, ratio=v=>v?.denominator?`${(v.value*100).toFixed(1)}% (${v.numerator}/${v.denominator})`:'等待人工审核';
  $('metrics').innerHTML=[['固定候选',state.rows.length],['姓名建议',state.run?suggested:'尚未关联'],['参考／邻近片段',refs],['本轮已审核',metrics?.counts.reviewed??0],['姓名关联准确率',ratio(metrics?.conditional_identity_accuracy)],['整体正确 coverage',ratio(metrics?.correct_coverage)]].map(([label,value])=>`<div class="metric"><span class="muted fine">${esc(label)}</span><b>${esc(value)}</b></div>`).join('');
  $('boundary').textContent='准确率使用本轮已人审且可确认姓名的投篮；coverage 保守包含“无法判断”。参考、非投篮、重复、明确画外遮挡及未审核记录单列。更改参考图后会产生新一轮。';
  const rows=visible();$('visibleCount').textContent=`显示 ${rows.length}/${state.rows.length}`;
  $('batch').disabled=!state.run||state.stale||!rows.some(r=>prediction(r)?.status==='suggested'&&!currentReview(r));
  $('grid').innerHTML=rows.map(card).join('')||'<div class="noResults">当前筛选没有片段。</div>';
  for(const el of document.querySelectorAll('[data-shot] [data-op]'))el.dataset.focus??=el.dataset.op+'-'+el.closest('[data-shot]').dataset.shot;
  for(const el of document.querySelectorAll('#players [data-op]'))el.dataset.focus??=el.dataset.op+'-'+(el.dataset.sample??el.dataset.player);
  if(focusKey)document.querySelector(`[data-focus="${CSS.escape(focusKey)}"]`)?.focus({preventScroll:true});
  window.scrollTo(0,pos);
}
function card(r){
  const p=prediction(r), selected=pick(r), review=currentReview(r), draft=drafts.get(r.id)??review??{};
  const pid=draft.player_id??p?.player_id??'', status=draft.status??'named';
  const reference=state.references.find(ref=>ref.sample_id===selected.sid);
  const label=p?.status==='suggested'?`建议：${name(p.player_id)}`:p?.status==='reference'?'参考／邻近片段':p?'算法不确定':'等待建立参考图';
  const reason=p?.status==='suggested'?`相似度 ${p.rankings[0].similarity.toFixed(3)} · 分差 ${p.margin.toFixed(3)}`:r.selected_track_id===null?'射手位置尚未确定，请先核对人物':p?.status==='reference'?'本片段不计入测试成绩':'可补充参考图，或人工确认名字';
  return `<article class="card ${review?'done':''}" data-shot="${esc(r.id)}"><div class="cardHead"><b>${esc(r.video_name)} · ${r.ordinal}</b><span class="badge ${review?'green':p?.status==='suggested'?'orange':''}">${review?'已保存':p?.status==='suggested'?'姓名建议':'待处理'}</span></div><div class="photo">${selected.sample?`<img loading="lazy" src="${media(selected.sample.image)}" alt="${esc(r.video_name)} ${time(r.event_time_ms)} 人物 P${selected.trackId}">`:'<div class="empty">射手尚未确定<br>请选择人物框或查看上下文</div>'}</div><div class="body"><div class="fine muted">${time(r.event_time_ms)} · 冻结定位 ${r.selected_track_id===null?'未知':'P'+r.selected_track_id}</div><div class="prediction"><b>${esc(label)}</b><span class="fine muted">${esc(reason)}</span></div><label>画面人物 <select data-op="track" data-focus="track-${esc(r.id)}"><option value="">请选择人物</option>${r.tracks.map(t=>`<option value="${t.id}" ${selected.trackId===t.id?'selected':''}>P${t.id}${t.id===r.selected_track_id?' · 算法所选':''}</option>`).join('')}</select></label><div class="row"><button data-op="prev" ${!selected.sample?'disabled':''} aria-label="查看前一张人物图">← 前帧</button><span class="fine">${selected.sample?time(selected.sample.time_ms):'—'}</span><button data-op="next" ${!selected.sample?'disabled':''} aria-label="查看后一张人物图">后帧 →</button></div><div class="row"><button data-op="context">全幅与人物框</button><button data-op="clip">代理短视频</button></div><button class="wide ${reference?'selectedRef':''}" data-op="reference" ${!selected.sample?'disabled':''}>${reference?`已为 ${esc(name(reference.player_id))} 的参考`:`确认此人为 ${esc(name(activeRef))} · 加入参考`}</button><label>审核结果 <select data-op="status" data-focus="status-${esc(r.id)}">${[['named','可确认姓名'],['unknown','无法判断／没有框到'],['not_shot','不是投篮'],['unobservable','画外／完全遮挡'],['duplicate','重复候选']].map(([v,n])=>`<option value="${v}" ${status===v?'selected':''}>${n}</option>`).join('')}</select></label><label>实际球员 <select data-op="name" data-focus="name-${esc(r.id)}">${playerOptions(pid,true)}</select></label><label>备注 <textarea data-op="note" data-focus="note-${esc(r.id)}" maxlength="2000" placeholder="可注明框错人、选帧问题或重复对象">${esc(draft.note??'')}</textarea></label><button class="primary wide" data-op="save" ${!state.run||state.stale?'disabled':''}>${review?'更新审核':'保存审核'}</button></div></article>`;
}
function rowFor(target){return state.rows.find(r=>r.id===target.closest('[data-shot]')?.dataset.shot);}
function draftFor(r){let d=drafts.get(r.id);if(!d){d={...(currentReview(r)??{}),status:currentReview(r)?.status??'named',player_id:currentReview(r)?.player_id??prediction(r)?.player_id??'',note:currentReview(r)?.note??''};drafts.set(r.id,d);}return d;}
function reviewItem(r){const d=draftFor(r);return {shot_id:r.id,...d,track_id:pick(r).trackId};}
function showDetail(r,clip=false){
  returnFocus=document.activeElement;const s=pick(r).sample??state.samples[r.tracks.flatMap(t=>t.sample_ids)[0]];$('detailTitle').textContent=`${r.video_name} · ${time(r.event_time_ms)} · ${clip?'代理短视频':'全幅人物框'}`;
  $('detailContent').innerHTML=clip?`<video controls preload="metadata" src="${media(r.video_asset)}#t=${r.clip_start},${r.clip_end}"></video><p>仅播放出手附近片段；输入和播放均为分析代理。</p>`:s?`<img src="${media(s.context)}" alt="全幅上下文，人物框按 P 编号"><p>当前卡片选择 P${pick(r).trackId}。回到卡片可切换人物。</p>`:'<p>暂无人物图。可查看代理短视频，并将无法判断的原因写入备注。</p>';
  $('detail').showModal();if(clip){const v=$('detailContent').querySelector('video');v.addEventListener('loadedmetadata',()=>{v.currentTime=r.clip_start;},{once:true});v.addEventListener('timeupdate',()=>{if(v.currentTime>r.clip_end)v.pause();});}
}
function openName(id){renameId=id;returnFocus=document.activeElement;$('newName').value=id?name(id):'';$('nameDialog').showModal();$('newName').focus();}
function confirmAction(text){
  const dialog=$('confirmDialog'), previous=document.activeElement;
  $('confirmText').textContent=text;
  return new Promise(resolve=>{
    let answered=false;
    const finish=value=>{
      if(answered)return;answered=true;
      dialog.close();dialog.removeEventListener('cancel',cancel);
      $('confirmProceed').onclick=null;$('confirmCancel').onclick=null;
      if(previous?.isConnected)previous.focus();resolve(value);
    };
    const cancel=event=>{event.preventDefault();finish(false);};
    $('confirmProceed').onclick=()=>finish(true);$('confirmCancel').onclick=()=>finish(false);
    dialog.addEventListener('cancel',cancel);dialog.showModal();$('confirmCancel').focus();
  });
}
document.addEventListener('click',async e=>{
  const button=e.target.closest('button[data-op]');if(!button||busy)return;const op=button.dataset.op;
  if(op==='rename')return openName(button.dataset.player);
  if(op==='removeRef')return act({action:'reference',sample_id:button.dataset.sample,remove:true},'已移除参考图；请重新关联');
  const r=rowFor(button);if(!r)return;const value=pick(r);
  if(op==='prev'||op==='next'){if(!value.track)return;const ids=value.track.sample_ids,index=ids.indexOf(value.sid);choices.set(r.id,{trackId:value.trackId,sid:ids[(index+(op==='next'?1:-1)+ids.length)%ids.length]});render();}
  if(op==='context'||op==='clip')showDetail(r,op==='clip');
  if(op==='reference')await act({action:'reference',sample_id:value.sid,player_id:activeRef,human_confirmed:true},'参考人物已确认；不会把此片段计入测试');
  if(op==='save'){if(await act({action:'review',run_id:state.run_id,items:[reviewItem(r)]})){drafts.delete(r.id);render();}}
});
$('grid').addEventListener('change',e=>{const r=rowFor(e.target);if(!r)return;const op=e.target.dataset.op;if(op==='track'){choices.set(r.id,{trackId:e.target.value?Number(e.target.value):null});render();}else if(op==='status')draftFor(r).status=e.target.value;else if(op==='name')draftFor(r).player_id=e.target.value;});
$('grid').addEventListener('input',e=>{const r=rowFor(e.target);if(r&&e.target.dataset.op==='note')draftFor(r).note=e.target.value;});
for(const id of ['video','filter','playerFilter'])$(id).addEventListener('change',render);
$('refPlayer').onchange=()=>{activeRef=$('refPlayer').value;render();};
$('addPlayer').onclick=()=>openName(null);
$('nameForm').onsubmit=async e=>{e.preventDefault();if(await act({action:'player',player_id:renameId,name:$('newName').value},'球员名字已保存'))$('nameDialog').close();};
$('cancelName').onclick=()=>$('nameDialog').close();
$('associate').onclick=async()=>{if(drafts.size&&!await confirmAction('当前有未保存的审核选择。重新关联会保留已保存记录，但未保存的选择会清空。继续吗？'))return;if(await act({action:'associate'},'自动关联完成；现在可审核姓名建议')){drafts.clear();render();}};
$('batch').onclick=async()=>{const rows=visible().filter(r=>prediction(r)?.status==='suggested'&&!currentReview(r)&&!drafts.has(r.id)&&!choices.has(r.id));if(!rows.length){message('当前建议均已编辑，请逐条保存，避免覆盖纠正内容。');return;}if(!await confirmAction(`请确认你已检查当前筛选的 ${rows.length} 条未编辑姓名建议。保存后可撤销。`))return;const items=rows.map(r=>({shot_id:r.id,status:'named',player_id:prediction(r).player_id,track_id:r.selected_track_id,note:''}));await act({action:'review',run_id:state.run_id,items},`已确认 ${items.length} 条建议`);};
$('undo').onclick=()=>act({action:'undo'},'已撤销上次审核');$('refresh').onclick=load;
$('closeDetail').onclick=()=>$('detail').close();
for(const id of ['detail','nameDialog'])$(id).addEventListener('close',()=>{const v=$('detailContent').querySelector('video');if(v)v.pause();if(returnFocus?.isConnected)returnFocus.focus();else $('refPlayer').focus();});
load();
