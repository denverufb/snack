(()=>{
'use strict';
const cfg=window.SNACK_PASS_CONFIG||{};if(!window.supabase||!cfg.supabaseUrl||!cfg.supabaseAnonKey)return;
const db=window.supabase.createClient(cfg.supabaseUrl,cfg.supabaseAnonKey);
const $=id=>document.getElementById(id);
const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
let records=[],busy=false,loadedOnce=false,showing=false;
window.PANTRY_ACTIVITY_ACTIVE=true;
const status=s=>{$('activity-feedback').textContent=s;};
async function rpc(fn,args){const {data,error}=await db.rpc(fn,args);if(error)throw error;return data;}
async function load(){
 if(busy)return;
 busy=true;status('Loading activity...');
 try{
  const [tx,students,snacks]=await Promise.all([
   db.from('transactions').select('id,kind,student_id,snack_id,delta_points,balance_after,note,created_at,archived_at').is('archived_at',null).order('created_at',{ascending:false}).limit(200),
   db.from('students').select('id,full_name').limit(1000),
   db.from('snacks').select('id,name').limit(1000)
  ]);
  if(tx.error)throw tx.error;if(students.error)throw students.error;if(snacks.error)throw snacks.error;
  const sn=new Map((students.data||[]).map(x=>[x.id,x.full_name]));
  const pr=new Map((snacks.data||[]).map(x=>[x.id,x.name]));
  records=(tx.data||[]).map(t=>({...t,studentName:sn.get(t.student_id)||'Unlinked student',productName:pr.get(t.snack_id)||t.note||'—'}));
  loadedOnce=true;draw();status('Showing '+records.length+' visible transactions.');
 }catch(e){status('Activity could not load. Run upgrade_activity_inventory.sql in Supabase. '+e.message);}
 finally{busy=false;}
}
function draw(){
 const kind=$('activity-kind').value;
 const found=records.filter(t=>kind==='all'||t.kind===kind);
 $('activity-rows').innerHTML=found.map(t=>'<tr data-id="'+esc(t.id)+'"><td><input type="checkbox" class="opening-choice" value="'+esc(t.id)+'" aria-label="Select for opening cleanup"></td><td>'+esc(new Date(t.created_at).toLocaleString())+'</td><td>'+esc(t.studentName)+'</td><td>'+esc(t.kind)+'</td><td>'+esc(t.productName)+'</td><td>'+t.delta_points+'</td><td>'+t.balance_after+'</td><td><button type="button" class="btn smallbtn danger" data-remove-entry="'+esc(t.id)+'">Remove</button></td></tr>').join('')||'<tr><td colspan="7" class="empty">No visible records.</td></tr>';
}
$('activity-rows').addEventListener('click',async e=>{
 const btn=e.target.closest('[data-remove-entry]');if(!btn)return;
 e.preventDefault();e.stopImmediatePropagation();
 const tx=records.find(x=>x.id===btn.dataset.removeEntry);
 if(!tx)return;
 if(!window.PANTRY_IS_ADMIN){status('Only administrators can remove activity.');return;}
 if(!confirm('Hide this '+tx.kind+' from Activity and financial reports? Points and inventory stay unchanged.'))return;
 const adminCode=await window.PANTRY_SCAN_ADMIN_BARCODE();
 if(!adminCode)return;
 btn.disabled=true;btn.textContent='Removing...';status('Verifying administrator barcode...');
 try{
  await rpc('admin_remove_activity',{p_transaction_id:tx.id,p_admin_barcode:adminCode});
  records=records.filter(x=>x.id!==tx.id);
  draw();status('Entry removed from Activity and reporting.');
  window.dispatchEvent(new Event('pantry-updated'));
 }catch(err){btn.disabled=false;btn.textContent='Remove';status('Removal failed: '+err.message);}
},true);
$('activity-kind').addEventListener('change',draw);
$('refresh-activity').addEventListener('click',()=>load(),true);
document.querySelector('[data-tab="activity"]').addEventListener('click',()=>{
 if(!loadedOnce)load();else draw();
},true);
window.addEventListener('pantry-updated',()=>{loadedOnce=false;});
})();