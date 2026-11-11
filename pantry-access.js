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
let cashiers=[],selectedCashierId=null;

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
function esc(value){return String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));}
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
async function loadCashiers(){
 if(!window.PANTRY_IS_ADMIN)return;
 const status=$('cashier-status');
 status.textContent='Loading cashier accounts...';
 try{
  const data=await rpc('get_admin_cashiers');
  cashiers=data.cashiers||[];
  $('cashier-count').textContent=(data.active_count||0)+' of '+(data.limit||15)+' active';
  $('cashier-create').disabled=Number(data.active_count||0)>=Number(data.limit||15);
  $('cashier-rows').innerHTML=cashiers.map(c=>
   '<tr class="'+(c.active?'':'inactive')+'"><td><strong>'+esc(c.display_name)+'</strong></td><td>'+esc(c.email||'Not recorded')+'</td><td><span class="tag '+(c.active?'green':'')+'">'+(c.active?'Active':'Disabled')+'</span></td><td>'+Number(c.purchase_count||0)+'</td><td>'+cash(c.sales_total)+'</td><td>'+(c.last_sale?esc(new Date(c.last_sale).toLocaleString()):'No purchases')+'</td><td class="actions"><button class="btn smallbtn" data-cashier-action="history" data-id="'+c.id+'">Purchases</button> <button class="btn smallbtn" data-cashier-action="toggle" data-id="'+c.id+'">'+(c.active?'Disable':'Enable')+'</button> '+(c.email?'<button class="btn smallbtn" data-cashier-action="reset" data-id="'+c.id+'">Reset password</button>':'')+'</td></tr>'
  ).join('')||'<tr><td colspan="7" class="empty">No cashier accounts yet.</td></tr>';
  status.textContent='Cashier accounts are ready.';
 }catch(e){
  status.textContent='Cashier accounts are unavailable. Run upgrade_cashier_accounts.sql. '+e.message;
 }
}
async function loadCashierPurchases(staffId){
 if(!window.PANTRY_IS_ADMIN)return;
 const cashier=cashiers.find(c=>c.id===staffId);
 if(cashier)$('cashier-purchase-title').textContent=cashier.display_name+' purchase history';
 $('cashier-purchase-status').textContent='Loading purchase history...';
 try{
  const data=await rpc('get_admin_cashier_purchases',{p_staff_id:staffId,p_limit:250});
  const purchases=data.purchases||[];
  $('cashier-purchase-rows').innerHTML=purchases.map(p=>
   '<tr><td>'+esc(new Date(p.created_at).toLocaleString())+'</td><td>'+esc(p.student_name)+'</td><td>'+esc(p.snack_name)+'</td><td>'+cash(p.amount)+'</td><td>'+esc(p.payment_type)+'</td><td><span class="tag '+(p.status==='completed'?'green':'orange')+'">'+esc(p.status)+'</span></td></tr>'
  ).join('')||'<tr><td colspan="6" class="empty">No purchases recorded for this cashier.</td></tr>';
  $('cashier-purchase-status').textContent=purchases.length+' purchase record'+(purchases.length===1?'':'s')+' shown.';
 }catch(e){
  $('cashier-purchase-status').textContent='Could not load cashier purchases: '+e.message;
 }
}
async function loadAdminData(){
 await Promise.all([loadAccount(),loadCashiers()]);
 if(selectedCashierId&&cashiers.some(c=>c.id===selectedCashierId))loadCashierPurchases(selectedCashierId);
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
  if(isAdmin)loadAdminData();
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
  loadAdminData();
 });
 document.querySelectorAll('.nav button').forEach(button=>{
  if(button!==adminNav)button.addEventListener('click',()=>section.classList.add('hidden'));
 });
}
$('admin-refresh')?.addEventListener('click',loadAdminData);
$('cashier-refresh')?.addEventListener('click',loadCashiers);
$('cashier-form')?.addEventListener('submit',async e=>{
 e.preventDefault();
 if(!window.PANTRY_IS_ADMIN)return;
 const displayName=$('cashier-name').value.trim();
 const email=$('cashier-email').value.trim().toLowerCase();
 const password=$('cashier-password').value;
 const status=$('cashier-status');
 if(displayName.length<2||displayName.length>100){status.textContent='Enter the cashier’s full name.';return;}
 if(password.length<12||password.length>72){status.textContent='Temporary password must be 12 to 72 characters.';return;}
 const button=$('cashier-create');button.disabled=true;status.textContent='Creating the secure cashier login...';
 try{
  const {data,error}=await db.functions.invoke('create-cashier',{body:{display_name:displayName,email,password}});
  if(error){
   let message=error.message;
   try{const body=await error.context.clone().json();message=body.error||message;}catch(_ignored){}
   throw new Error(message);
  }
  e.target.reset();
  const createdName=data?.cashier?.display_name||displayName;
  await loadCashiers();
  status.textContent='Created '+createdName+'. Share the temporary password privately; it will be replaced at first sign-in.';
 }catch(err){status.textContent='Account creation failed: '+err.message;}
 finally{button.disabled=cashiers.filter(c=>c.active).length>=15;}
});
$('cashier-rows')?.addEventListener('click',async e=>{
 const button=e.target.closest('[data-cashier-action]');if(!button||!window.PANTRY_IS_ADMIN)return;
 const cashier=cashiers.find(c=>c.id===button.dataset.id);if(!cashier)return;
 if(button.dataset.cashierAction==='history'){
  selectedCashierId=cashier.id;
  await loadCashierPurchases(cashier.id);
  return;
 }
 if(button.dataset.cashierAction==='toggle'){
  if(!confirm((cashier.active?'Disable ':'Enable ')+cashier.display_name+'?'))return;
  button.disabled=true;
  try{await rpc('set_cashier_active',{p_staff_id:cashier.id,p_active:!cashier.active});await loadCashiers();}
  catch(err){$('cashier-status').textContent=err.message;button.disabled=false;}
  return;
 }
 if(button.dataset.cashierAction==='reset'){
  if(!confirm('Send a password-reset email to '+cashier.email+'?'))return;
  button.disabled=true;
  try{
   const redirectTo=window.location.origin+window.location.pathname;
   const {error}=await db.auth.resetPasswordForEmail(cashier.email,{redirectTo});
   if(error)throw error;
   $('cashier-status').textContent='Password-reset email sent to '+cashier.email+'.';
  }catch(err){$('cashier-status').textContent='Reset email failed: '+err.message;}
  finally{button.disabled=false;}
 }
});
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
