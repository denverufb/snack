(function activityCleanupAddon(){
'use strict';
const cfg=window.SNACK_PASS_CONFIG||{};
if(!window.supabase||!cfg.supabaseUrl||!cfg.supabaseAnonKey)return;
const db=window.supabase.createClient(cfg.supabaseUrl,cfg.supabaseAnonKey);
const $=id=>document.getElementById(id);
const escape=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
let busy=false,installed=false;
function showError(e){alert(e.message||String(e))}
async function rpc(name,args){const {data,error}=await db.rpc(name,args);if(error)throw error;return data;}
async function render(){
 if(busy||!installed||$('tab-activity').classList.contains('hidden'))return;
 busy=true;
 try{
  const [t,students,snacks]=await Promise.all([
   db.from('transactions').select('id,kind,student_id,snack_id,delta_points,balance_after,note,created_at,archived_at')
     .is('archived_at',null).order('created_at',{ascending:false}).limit(200),
   db.from('students').select('id,full_name').limit(1000),
   db.from('snacks').select('id,name').limit(1000)
  ]);
  if(t.error)throw t.error;
  if(students.error)throw students.error;
  if(snacks.error)throw snacks.error;
  const names=new Map((students.data||[]).map(x=>[x.id,x.full_name]));
  const items=new Map((snacks.data||[]).map(x=>[x.id,x.name]));
  const kind=$('activity-kind').value;
  const rows=(t.data||[]).filter(x=>kind==='all'||x.kind===kind);
  $('activity-rows').innerHTML=rows.map(x=>'<tr><td>'+escape(new Date(x.created_at).toLocaleString())+'</td><td>'+escape(names.get(x.student_id)||'Unlinked student')+'</td><td>'+escape(x.kind)+'</td><td>'+escape(items.get(x.snack_id)||x.note||'—')+'</td><td>'+x.delta_points+'</td><td>'+x.balance_after+'</td><td><button type="button" class="btn smallbtn danger" data-hide-tx="'+escape(x.id)+'">Remove</button></td></tr>').join('')||'<tr><td colspan="7" class="empty">No visible transactions.</td></tr>';
  $('activity-note').textContent='Remove hides an entry from this list and the financial report. It does not undo points, cash, or stock. The entry remains archived in Supabase.';
 }catch(e){$('activity-note').textContent='Run upgrade_activity_inventory.sql in Supabase to enable Activity cleanup: '+e.message;}
 finally{busy=false;}
}
async function remove(event){
 const button=event.target.closest('[data-hide-tx]');
 if(!button)return;
 event.preventDefault();event.stopImmediatePropagation();
 if(!confirm('Remove this activity entry from the list and reports? Current student points, stock and collected cash will NOT change.'))return;
 const pin=prompt('Enter administrator PIN:');if(pin===null)return;
 button.disabled=true;
 try{await rpc('remove_activity_entry',{p_transaction_id:button.dataset.hideTx,p_pin:pin});await render();$('f-refresh')?.click();}
 catch(e){button.disabled=false;showError(e);}
}
async function bulk(){
 const name=prompt('Enter the exact saved student name for your three real transactions:','Aereon Robinson');
 if(name===null||!name.trim())return;
 try{
  const preview=await rpc('preview_activity_cleanup',{p_keep_student_name:name.trim()});
  if(Number(preview.kept)!==3){alert('Found '+preview.kept+' entries under that exact name. Nothing removed because the count is not three.');return;}
  if(!confirm('Keep the 3 entries for '+name+' and hide '+preview.would_remove+' other records from Activity AND financial reports? Existing balances and stock will not be adjusted.'))return;
  const pin=prompt('Administrator PIN for cleanup:');if(pin===null)return;
  const result=await rpc('keep_only_three_activity',{p_keep_student_name:name.trim(),p_pin:pin});
  await render();$('f-refresh')?.click();alert(result.removed+' entries hidden, '+result.retained+' kept. Supabase retains an archive.');
 }catch(e){showError(e)}
}
function install(){
 if(installed||!$('tab-activity')||!$('app')||$('app').classList.contains('hidden'))return;
 installed=true;
 const section=$('tab-activity'),bar=document.createElement('div');
 bar.className='buttons';bar.style.margin='10px 0';
 const keep=document.createElement('button');keep.className='btn danger';keep.type='button';keep.textContent='Keep my 3 real entries';
 const refresh=document.createElement('button');refresh.className='btn';refresh.type='button';refresh.textContent='Refresh visible Activity';
 const note=document.createElement('p');note.className='small';note.id='activity-note';
 bar.append(keep,refresh);section.insertBefore(bar,section.querySelector('table').parentElement);
 bar.after(note);keep.addEventListener('click',bulk);refresh.addEventListener('click',render);
 $('activity-rows').addEventListener('click',remove,true);
 $('activity-kind').addEventListener('change',()=>setTimeout(render,0));
 $('refresh-activity').addEventListener('click',()=>setTimeout(render,300));
 $('app').querySelector('[data-tab="activity"]').addEventListener('click',()=>setTimeout(render,100));
}
setInterval(()=>{install();if(installed&&!$('tab-activity').classList.contains('hidden'))render();},5000);
install();
})();
