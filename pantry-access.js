(() => {
'use strict';
const cfg=window.SNACK_PASS_CONFIG||{};
if(!window.supabase||!cfg.supabaseUrl||!cfg.supabaseAnonKey)return;
const db=window.supabase.createClient(cfg.supabaseUrl,cfg.supabaseAnonKey);
const $=id=>document.getElementById(id);
window.PANTRY_IS_ADMIN=false;
window.PANTRY_CAN_VIEW_ACTIVITY=false;
window.PANTRY_CAN_VIEW_FINANCES=false;

function scanAdminBarcode(){
 return new Promise(resolve=>{
  const backdrop=document.createElement('div');
  backdrop.style.cssText='position:fixed;inset:0;background:rgba(4,20,35,.72);z-index:999;display:flex;align-items:center;justify-content:center;padding:20px';
  const panel=document.createElement('div');
  panel.style.cssText='background:#fff;color:#102c40;padding:26px;border-radius:16px;max-width:460px;width:100%;box-shadow:0 20px 60px #0004';
  const title=document.createElement('h2');
  title.textContent='Scan administrator student ID';
  const copy=document.createElement('p');
  copy.textContent='Scan your registered student ID barcode to authorize this removal. You must also be signed in as administrator.';
  const input=document.createElement('input');
  input.type='password';input.className='field';input.autocomplete='off';
  input.placeholder='Scan your ID here, then Enter';
  input.setAttribute('aria-label','Administrator barcode');
  const cancel=document.createElement('button');
  cancel.type='button';cancel.className='btn';cancel.textContent='Cancel';
  let done=false;
  const close=value=>{
   if(done)return;done=true;backdrop.remove();resolve(value);
  };
  input.addEventListener('keydown',e=>{
   if(e.key==='Enter'){e.preventDefault();close(input.value.trim());}
   else if(e.key==='Escape'){e.preventDefault();close(null);}
  });
  cancel.addEventListener('click',()=>close(null));
  panel.append(title,copy,input,cancel);
  backdrop.appendChild(panel);
  document.body.appendChild(backdrop);input.focus();
 });
}
window.PANTRY_SCAN_ADMIN_BARCODE=scanAdminBarcode;

const section=$('tab-admin');
const adminNav=document.querySelector('[data-tab="admin"]');
const financeNav=document.querySelector('[data-tab="finances"]');
const activityNav=document.querySelector('[data-tab="activity"]');
const snackForm=$('snack-form')?.closest('section.card');
let role=null,opening=false;

function applyAccess({isAdmin=false,canViewActivity=false,canViewFinances=false}={}){
 window.PANTRY_IS_ADMIN=isAdmin;
 window.PANTRY_CAN_VIEW_ACTIVITY=canViewActivity;
 window.PANTRY_CAN_VIEW_FINANCES=canViewFinances;
 if(adminNav)adminNav.style.display=isAdmin?'':'none';
 if(activityNav)activityNav.style.display=canViewActivity?'':'none';
 if(financeNav)financeNav.style.display=canViewFinances?'':'none';
 if(snackForm)snackForm.style.display=isAdmin?'':'none';
 const tips=$('admin-only-note');
 if(tips)tips.style.display=isAdmin?'':'none';
 const adminWasOpen=section&&!section.classList.contains('hidden');
 if(!isAdmin&&section)section.classList.add('hidden');
 const blockedSection=(!canViewFinances&&!$('tab-finances').classList.contains('hidden'))||
   (!canViewActivity&&!$('tab-activity').classList.contains('hidden'))||
   (!isAdmin&&adminWasOpen);
 if(blockedSection){
  document.querySelector('[data-tab="checkout"]')?.click();
 }
 $('student-search')?.dispatchEvent(new Event('input'));
 window.dispatchEvent(new Event('pantry-role-ready'));
}
function cash(n){return '$'+Number(n||0).toFixed(2);}
async function rpc(name,args){
 const {data,error}=await db.rpc(name,args||{});
 if(error)throw error;return data;
}
async function loadAccount(){
 if(!window.PANTRY_IS_ADMIN||!section)return;
 const notice=$('admin-status');
 try{
  const data=await rpc('get_admin_account');
  notice.textContent=data.student_linked?'Administrator account is linked to '+data.student_name+'.':'Link your registered student barcode before enabling a tab or removing records.';
  $('admin-mode').value=data.account_mode||'points';
  $('admin-tab-balance').textContent=cash(data.tab_balance);
  $('admin-charged').textContent=cash(data.charged);
  $('admin-paid').textContent=cash(data.paid);
  $('admin-link-card').style.display=data.student_linked?'none':'';
  const [charges,payments]=await Promise.all([
    db.from('pantry_tab_charges').select('id,snack_name,amount,created_at')
      .is('voided_at',null).order('created_at',{ascending:false}).limit(100),
    db.from('pantry_tab_payments').select('id,amount,created_at')
      .is('voided_at',null).order('created_at',{ascending:false}).limit(100)
  ]);
  if(charges.error)throw charges.error;
  if(payments.error)throw payments.error;
  const events=[
    ...(charges.data||[]).map(x=>({id:x.id,label:x.snack_name,amount:x.amount,kind:'charge',time:x.created_at})),
    ...(payments.data||[]).map(x=>({id:x.id,label:'Payment received',amount:-x.amount,kind:'payment',time:x.created_at}))
  ].sort((a,b)=>new Date(b.time)-new Date(a.time));
  $('admin-tab-rows').innerHTML=events.map(t=>
   '<tr><td>'+new Date(t.time).toLocaleString()+'</td><td>'+
   String(t.label).replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]))+
   '</td><td>'+cash(t.amount)+'</td><td><button class="btn smallbtn danger" data-admin-tab-remove="'+t.kind+'" data-id="'+t.id+'">Remove</button></td></tr>'
  ).join('')||'<tr><td colspan="4">No tab activity yet.</td></tr>';
 }catch(e){notice.textContent='Administrator setup unavailable: '+e.message;}
}
async function syncRole(){
 try{
  const {data:session,error}=await db.auth.getSession();if(error)throw error;
  if(!session.session){role=null;applyAccess();return;}
  const result=await rpc('get_pantry_role');
  role=result.role;
  const isAdmin=role==='admin';
  applyAccess({
   isAdmin,
   canViewActivity:isAdmin||result.can_view_activity===true,
   canViewFinances:isAdmin||result.can_view_finances===true
  });
  if(isAdmin)loadAccount();
 }catch(e){role=null;applyAccess();}
}
if(adminNav){
 adminNav.addEventListener('click',()=>{
  if(!window.PANTRY_IS_ADMIN)return;
  for(const id of ['checkout','students','snacks','activity','finances']){
   $('tab-'+id)?.classList.add('hidden');
  }
  section.classList.remove('hidden');
  document.querySelectorAll('.nav button').forEach(b=>b.classList.toggle('active',b===adminNav));
  loadAccount();
 });
 document.querySelectorAll('.nav button').forEach(button=>{
  if(button!==adminNav)button.addEventListener('click',()=>section.classList.add('hidden'));
 });
}
$('admin-link-card')?.addEventListener('click',async()=>{
 const barcode=await scanAdminBarcode();if(!barcode)return;
 try{
  const result=await rpc('link_admin_student_barcode',{p_barcode:barcode});
  $('admin-status').textContent='Linked student ID for '+result.student_name+'.';
  await loadAccount();
 }catch(e){$('admin-status').textContent=e.message;}
});
$('admin-mode')?.addEventListener('change',async e=>{
 const prior=e.target.value==='tab'?'points':'tab';
 const value=e.target.value;
 try{
  if(!confirm('Switch your account to '+(value==='tab'?'running tab':'prepaid points')+' for future purchases? Existing charges are not converted.')){e.target.value=prior;return;}
  await rpc('set_admin_account_mode',{p_mode:value});
  await loadAccount();
 }catch(err){e.target.value=prior;$('admin-status').textContent=err.message;}
});
$('admin-pay-tab')?.addEventListener('click',async()=>{
 const raw=prompt('Payment received toward your tab (dollars):');if(raw===null)return;
 const amount=Number(raw);
 if(!Number.isFinite(amount)||amount<=0||Math.round(amount*100)!==amount*100){$('admin-status').textContent='Enter a positive dollar amount with no more than two decimals.';return;}
 if(!confirm('Confirm you actually received $'+amount.toFixed(2)+' toward this tab?'))return;
 try{await rpc('record_admin_tab_payment',{p_amount:amount,p_request_id:crypto.randomUUID()});await loadAccount();window.dispatchEvent(new Event('pantry-updated'));}
 catch(e){$('admin-status').textContent=e.message;}
});
$('admin-tab-rows')?.addEventListener('click',async e=>{
 const button=e.target.closest('[data-admin-tab-remove]');if(!button)return;
 const barcode=await scanAdminBarcode();if(!barcode)return;
 const fn=button.dataset.adminTabRemove==='charge'?'admin_remove_tab_charge':'admin_remove_tab_payment';
 const args=button.dataset.adminTabRemove==='charge'
  ?{p_charge_id:button.dataset.id,p_admin_barcode:barcode}
  :{p_payment_id:button.dataset.id,p_admin_barcode:barcode};
 try{await rpc(fn,args);await loadAccount();window.dispatchEvent(new Event('pantry-updated'));}
 catch(err){$('admin-status').textContent=err.message;}
});
if(db.auth.onAuthStateChange){
 db.auth.onAuthStateChange(()=>setTimeout(syncRole,0));
}
applyAccess();
syncRole();
})();
