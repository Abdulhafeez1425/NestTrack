import { useEffect, useState } from 'react';

export type PropertyUnit = {
  id: string;
  name: string;
  description: string;
  tenantId?: string;
  rent: number;
  status?: string;
};

export type ManagedProperty = {
  id: string;
  orgId: string;
  name: string;
  address: string;
  image: string;
  units: PropertyUnit[];
};

type Tenant = { id: string; name: string; email: string; phone?: string; welfare?: string };
type Tenancy = { id: string; unitId: string; tenantId: string; startDate?: string; endDate?: string; rentAmount: number; status: string };
type PropertyDraft = { id?: string; name: string; address: string; image: string; units: PropertyUnit[] };
type UnitDraft = { id?: string; propertyId: string; name: string; description: string; rent: number };

const money = (amount: number) => `₦${amount.toLocaleString()}`;
const isOccupied = (unit: PropertyUnit) => Boolean(unit.tenantId) || unit.status === 'occupied';

function Icon({ name }: { name: 'edit' | 'trash' | 'plus' | 'chevron' | 'upload' | 'home' }) {
  const p = { width: 16, height: 16, viewBox: '0 0 24 24', fill: 'none', stroke: 'currentColor', strokeWidth: 1.8, strokeLinecap: 'round' as const, strokeLinejoin: 'round' as const };
  const paths: Record<string, React.ReactNode> = {
    edit: <><path d="M12 20h9"/><path d="M16.5 3.5a2.1 2.1 0 0 1 3 3L8 18l-4 1 1-4Z"/></>,
    trash: <><path d="M4 7h16"/><path d="M10 11v6M14 11v6"/><path d="M6 7l1 14h10l1-14"/><path d="M9 7V4h6v3"/></>,
    plus: <><path d="M12 5v14M5 12h14"/></>,
    chevron: <path d="m7 10 5 5 5-5"/>,
    upload: <><path d="M12 16V4"/><path d="m7 9 5-5 5 5"/><path d="M5 20h14"/></>,
    home: <><path d="m3 10 9-7 9 7"/><path d="M5 9v11h14V9"/></>,
  };
  return <svg {...p}>{paths[name]}</svg>;
}

export function PropertyEditor({ property, onClose, onSave }: { property?: ManagedProperty; onClose: () => void; onSave: (draft: PropertyDraft, imageFile?: File) => Promise<void> }) {
  const [name, setName] = useState(property?.name || '');
  const [address, setAddress] = useState(property?.address || '');
  const [image, setImage] = useState(property?.image || '');
  const [imageFile, setImageFile] = useState<File>();
  const [units, setUnits] = useState<PropertyUnit[]>(property?.units.map(u => ({ ...u })) || [{ id: 'new-unit-1', name: '', description: '', rent: 0 }]);
  const [preview, setPreview] = useState('');
  const [error, setError] = useState('');
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    if (!imageFile) { setPreview(''); return; }
    const url = URL.createObjectURL(imageFile); setPreview(url);
    return () => URL.revokeObjectURL(url);
  }, [imageFile]);

  const occupied = units.filter(isOccupied).length;
  const updateUnit = (index: number, changes: Partial<PropertyUnit>) => setUnits(current => current.map((u, i) => i === index ? { ...u, ...changes } : u));
  const addDraftUnit = () => setUnits(current => [...current, { id: `new-${Date.now()}`, name: '', description: '', rent: 0 }]);
  const removeDraftUnit = (id: string) => setUnits(current => current.length > 1 ? current.filter(u => u.id !== id) : current);

  const chooseImage = (file?: File) => {
    if (!file) return;
    if (!['image/jpeg', 'image/png', 'image/webp', 'image/gif'].includes(file.type)) return setError('Choose a JPEG, PNG, WebP or GIF image.');
    if (file.size > 10 * 1024 * 1024) return setError('Property images must be 10 MB or smaller.');
    setError(''); setImageFile(file); setImage('');
  };

  const submit = async (event: React.FormEvent) => {
    event.preventDefault(); setError('');
    if (!name.trim() || !address.trim()) return setError('Enter a property name and address.');
    if (!units.length || units.some(u => !u.name.trim())) return setError('Give every unit a name before saving the property.');
    if (units.some(u => !Number.isFinite(u.rent) || u.rent < 0)) return setError('Unit rent must be zero or greater.');
    setSaving(true);
    try {
      await onSave({ id: property?.id, name: name.trim(), address: address.trim(), image, units }, imageFile);
      onClose();
    } catch (e) { setError(e instanceof Error ? e.message : 'Property could not be saved.'); }
    finally { setSaving(false); }
  };

  return <div className="fixed inset-0 z-[60] overflow-y-auto bg-[#071d1b]/70 p-3 sm:p-6" onMouseDown={e => { if (e.target === e.currentTarget && !saving) onClose(); }}>
    <form onSubmit={submit} className="mx-auto my-2 max-w-5xl overflow-hidden rounded-[24px] border border-white/50 bg-white shadow-2xl sm:my-5">
      <div className="relative h-56 overflow-hidden bg-[#e8f0ed] sm:h-72">
        {preview || image ? <img src={preview || image} alt="Selected property" className="h-full w-full object-cover" /> : <div className="grid h-full place-items-center text-center text-sm text-[#6b807b]"><div><Icon name="home"/><span className="mt-2 block">Your selected property image will appear here</span></div></div>}
        <div className="absolute inset-x-0 top-0 flex items-center justify-between p-4 sm:p-5">
          <span className="rounded-full bg-[#173c35]/90 px-3 py-1.5 text-[10px] font-bold text-white">● Active listing</span>
          <button type="button" onClick={onClose} className="rounded-xl bg-white/90 px-3 py-2 text-lg text-[#34534d] shadow">×</button>
        </div>
        <label className="absolute bottom-4 right-4 flex cursor-pointer items-center gap-2 rounded-xl bg-white/95 px-3 py-2 text-xs font-bold text-[#175e51] shadow">
          <Icon name="upload"/>{imageFile?.name || (image ? 'Replace image' : 'Choose image')}
          <input className="sr-only" type="file" accept="image/jpeg,image/png,image/webp,image/gif" onChange={e => chooseImage(e.target.files?.[0])}/>
        </label>
      </div>

      <div className="p-5 sm:p-7">
        <div className="flex flex-wrap items-start justify-between gap-4">
          <div className="min-w-0 flex-1">
            <div className="text-[9px] font-bold uppercase tracking-[.18em] text-[#78908a]">Residential collection</div>
            <input value={name} onChange={e => setName(e.target.value)} placeholder="JIZBO Apartments" className="mt-1 w-full border-0 p-0 text-2xl font-semibold tracking-tight outline-none focus:ring-0 sm:text-3xl" required />
            <div className="mt-1 flex items-center gap-2 text-xs text-[#6b807b]"><span>⌖</span><input value={address} onChange={e => setAddress(e.target.value)} placeholder="Address to be added" className="min-w-0 flex-1 border-0 p-0 text-xs outline-none focus:ring-0" required /></div>
          </div>
          <button type="button" className="btn btn-ghost text-xs" onClick={() => document.querySelector<HTMLInputElement>('input[type=file]')?.click()}><Icon name="upload"/> Add property image</button>
        </div>

        <div className="mt-6 grid grid-cols-3 divide-x divide-[#dce9e6] rounded-2xl border border-[#e5eeeb] bg-[#f6faf9] py-3 text-center">
          <div><div className="text-lg font-extrabold">{units.length}</div><div className="text-[10px] text-[#78908a]">units</div></div>
          <div><div className="text-lg font-extrabold">{units.length - occupied}</div><div className="text-[10px] text-[#78908a]">ready</div></div>
          <div><div className="text-lg font-extrabold">{units.length ? Math.round(occupied / units.length * 100) : 0}%</div><div className="text-[10px] text-[#78908a]">managed</div></div>
        </div>

        <div className="mt-7 flex items-center justify-between border-b border-[#e7efec] pb-3">
          <div><div className="text-sm font-semibold">Units <span className="ml-1 rounded-full bg-[#e5f1ec] px-1.5 py-0.5 text-[10px]">{units.length}</span></div><p className="mt-1 text-[10px] text-[#78908a]">Add the spaces within this property.</p></div>
          <button type="button" className="btn btn-primary" onClick={addDraftUnit}><Icon name="plus"/> Add unit</button>
        </div>

        <div className="mt-3 space-y-2">
          {units.map((unit, index) => <div key={unit.id} className="rounded-xl border border-[#e1ece8] bg-[#fafcfb] p-3">
            {property ? <div className="grid gap-2 sm:grid-cols-[44px_1fr_1fr_150px] sm:items-center">
              <span className="grid h-9 w-9 place-items-center rounded-lg bg-[#e5f1e7] text-[10px] font-bold text-[#276d53]">{String(index + 1).padStart(2, '0')}</span>
              <div><div className="text-xs font-bold">Unit {unit.name}</div><div className="muted mt-1 text-[10px]">{unit.description || 'No description'}</div></div>
              <div className="text-xs font-semibold">{money(unit.rent)}</div>
              <div className="text-[10px] font-semibold text-[#78908a]">{isOccupied(unit) ? 'Occupied' : 'Ready'}</div>
            </div> : <div className="grid gap-2 sm:grid-cols-[44px_1fr_1fr_150px_auto] sm:items-center">
              <span className="grid h-9 w-9 place-items-center rounded-lg bg-[#e5f1e7] text-[10px] font-bold text-[#276d53]">{String(index + 1).padStart(2, '0')}</span>
              <input className="input" value={unit.name} onChange={e => updateUnit(index, { name: e.target.value })} placeholder="Unit 01A" aria-label={`Unit ${index + 1} name`}/>
              <input className="input" value={unit.description} onChange={e => updateUnit(index, { description: e.target.value })} placeholder="Ground floor / 2 bedrooms" aria-label={`Unit ${index + 1} description`}/>
              <input className="input" type="number" min="0" value={unit.rent || ''} onChange={e => updateUnit(index, { rent: Number(e.target.value) })} placeholder="Monthly rent" aria-label={`Unit ${index + 1} rent`}/>
              {units.length > 1 && <button type="button" className="rounded-lg border border-[#dce9e6] bg-white p-2 text-[#b42318]" onClick={() => removeDraftUnit(unit.id)} title="Remove unit"><Icon name="trash"/></button>}
            </div>}
          </div>)}
        </div>
        {error && <div role="alert" className="mt-4 rounded-xl bg-[#fff0ef] p-3 text-sm text-[#b42318]">{error}</div>}
      </div>
      <div className="flex justify-end gap-2 border-t border-[#e5eeeb] bg-[#fbfdfc] px-5 py-4 sm:px-7">
        <button type="button" className="btn btn-ghost" disabled={saving} onClick={onClose}>Cancel</button>
        <button type="submit" className="btn btn-primary" disabled={saving}>{saving ? 'Saving…' : property ? 'Save changes' : 'Create property'}</button>
      </div>
    </form>
  </div>;
}

function UnitEditor({ initial, onClose, onSave }: { initial: UnitDraft; onClose: () => void; onSave: (unit: UnitDraft) => Promise<void> }) {
  const [name, setName] = useState(initial.name); const [description, setDescription] = useState(initial.description); const [rent, setRent] = useState(String(initial.rent || '')); const [error, setError] = useState(''); const [saving, setSaving] = useState(false);
  return <div className="fixed inset-0 z-[70] grid place-items-center bg-[#071d1b]/70 p-4">
    <form className="w-full max-w-md rounded-2xl bg-white p-6 shadow-2xl" onSubmit={async e => { e.preventDefault(); if (!name.trim() || Number(rent) < 0) return setError('Enter a unit name and a non-negative rent amount.'); setSaving(true); setError(''); try { await onSave({ ...initial, name: name.trim(), description: description.trim(), rent: Number(rent) }); onClose(); } catch (err) { setError(err instanceof Error ? err.message : 'Unit could not be saved.'); } finally { setSaving(false); } }}>
      <div className="text-[9px] font-bold uppercase tracking-[.18em] text-[#78908a]">Property unit</div><h2 className="mt-1 text-lg font-extrabold">{initial.id ? 'Edit unit' : 'Add unit'}</h2>
      <label className="mt-4 block text-xs font-bold">Unit name<input className="input mt-1" value={name} onChange={e => setName(e.target.value)} required/></label>
      <label className="mt-3 block text-xs font-bold">Description<input className="input mt-1" value={description} onChange={e => setDescription(e.target.value)} placeholder="Bedrooms, floor or features"/></label>
      <label className="mt-3 block text-xs font-bold">Monthly rent<input className="input mt-1" type="number" min="0" value={rent} onChange={e => setRent(e.target.value)} required/></label>
      {error && <div className="mt-3 rounded-xl bg-[#fff0ef] p-3 text-sm text-[#b42318]">{error}</div>}
      <div className="mt-5 flex justify-end gap-2"><button type="button" className="btn btn-ghost" disabled={saving} onClick={onClose}>Cancel</button><button type="submit" className="btn btn-primary" disabled={saving}>{saving ? 'Saving…' : 'Save unit'}</button></div>
    </form>
  </div>;
}

function TenantAssignment({ unit, tenants, defaultRent, onClose, onAssign }: { unit: PropertyUnit; tenants: Tenant[]; defaultRent: number; onClose: () => void; onAssign: (tenantId: string, startDate: string, rent: number) => Promise<void> }) {
  const [tenantId, setTenantId] = useState(tenants[0]?.id || '');
  const [startDate, setStartDate] = useState(new Date().toISOString().slice(0, 10));
  const [rent, setRent] = useState(String(defaultRent || '')); const [error, setError] = useState(''); const [saving, setSaving] = useState(false);
  return <div className="fixed inset-0 z-[75] grid place-items-center bg-[#071d1b]/70 p-4">
    <form className="w-full max-w-md rounded-2xl bg-white p-6 shadow-2xl" onSubmit={async e => { e.preventDefault(); if (!tenantId) return setError('Select a tenant account.'); if (Number(rent) < 0) return setError('Rent must be zero or greater.'); setSaving(true); setError(''); try { await onAssign(tenantId, startDate, Number(rent)); onClose(); } catch (err) { setError(err instanceof Error ? err.message : 'Tenant could not be assigned.'); } finally { setSaving(false); } }}>
      <div className="text-[9px] font-bold uppercase tracking-[.18em] text-[#78908a]">Unit {unit.name}</div><h2 className="mt-1 text-xl font-extrabold">Assign tenant</h2><p className="mt-1 text-xs text-[#78908a]">Select an existing tenant account. No invitation link is required.</p>
      {!tenants.length ? <div className="mt-5 rounded-xl bg-[#fff7e6] p-4 text-sm text-[#8a5a08]">No standalone tenant accounts are available yet. Ask the tenant to create a NestTrack account first.</div> : <>
        <label className="mt-5 block text-xs font-bold">Tenant<select className="input mt-1" value={tenantId} onChange={e => setTenantId(e.target.value)}>{tenants.map(t => <option key={t.id} value={t.id}>{t.name} · {t.email}</option>)}</select></label>
        <label className="mt-3 block text-xs font-bold">Tenancy start date<input className="input mt-1" type="date" value={startDate} onChange={e => setStartDate(e.target.value)} required/></label>
        <label className="mt-3 block text-xs font-bold">Contract rent<input className="input mt-1" type="number" min="0" value={rent} onChange={e => setRent(e.target.value)} required/></label>
      </>}
      {error && <div className="mt-3 rounded-xl bg-[#fff0ef] p-3 text-sm text-[#b42318]">{error}</div>}
      <div className="mt-5 flex justify-end gap-2"><button type="button" className="btn btn-ghost" onClick={onClose}>Cancel</button><button type="submit" className="btn btn-primary" disabled={saving || !tenants.length}>{saving ? 'Assigning…' : 'Assign tenant'}</button></div>
    </form>
  </div>;
}

export function PropertyCollection({ properties, tenants, tenantCandidates, tenancies, canManage, canDelete, onAdd, onSaveProperty, onAddUnit, onSaveUnit, onAssignTenant, onDeleteProperty, onDeleteUnit }: {
  properties: ManagedProperty[]; tenants: Tenant[]; tenantCandidates: Tenant[]; tenancies: Tenancy[]; canManage: boolean; canDelete: boolean; onAdd: () => void; onSaveProperty: (draft: PropertyDraft, imageFile?: File) => Promise<void>; onAddUnit: (unit: UnitDraft) => Promise<void>; onSaveUnit: (unit: UnitDraft) => Promise<void>; onAssignTenant: (unitId: string, tenantId: string, startDate: string, rentAmount: number) => Promise<void>; onDeleteProperty: (id: string) => void; onDeleteUnit: (id: string) => void;
}) {
  const [expandedUnit, setExpandedUnit] = useState(''); const [editingProperty, setEditingProperty] = useState<ManagedProperty>(); const [editingUnit, setEditingUnit] = useState<UnitDraft>(); const [assigningUnit, setAssigningUnit] = useState<{ unit: PropertyUnit; propertyId: string }>();
  const candidates = tenantCandidates;

  return <>
    <div className="mb-6 flex flex-wrap items-end justify-between gap-4"><div><div className="eyebrow">Portfolio</div><h1 className="mt-1 text-3xl font-extrabold tracking-tight">Properties</h1><p className="muted mt-1 text-sm">Buildings, units and their current tenancy details.</p></div>{canManage && <button className="btn btn-primary" onClick={onAdd}><Icon name="plus"/> Add property</button>}</div>
    {!properties.length && <div className="card p-8 text-center"><div className="font-extrabold">No properties yet</div><p className="muted mt-2 text-sm">Create your first property and add its units.</p>{canManage && <button className="btn btn-primary mt-4" onClick={onAdd}>Add property</button>}</div>}
    <div className="space-y-7">
      {properties.map(property => {
        const occupied = property.units.filter(isOccupied).length;
        return <article key={property.id} className="overflow-hidden rounded-[22px] border border-[#dce9e6] bg-white shadow-sm">
          <div className="relative h-52 bg-[#e7efec] sm:h-72">{property.image && <img src={property.image} alt={property.name} className="h-full w-full object-cover"/>}<span className="absolute left-4 top-4 rounded-full bg-[#173c35]/90 px-3 py-1.5 text-[10px] font-bold text-white">● Active listing</span><span className="absolute bottom-4 left-4 rounded bg-[#0b2927]/65 px-2 py-1 text-[10px] font-bold text-white">PROPERTY</span>{canManage && <div className="absolute right-4 top-4 flex gap-2"><button className="grid h-9 w-9 place-items-center rounded-xl bg-white/95 text-[#174d43] shadow" onClick={() => setEditingProperty(property)} title="Edit property"><Icon name="edit"/></button>{canDelete && <button className="grid h-9 w-9 place-items-center rounded-xl bg-white/95 text-red-700 shadow" onClick={() => onDeleteProperty(property.id)} title="Delete property"><Icon name="trash"/></button>}</div>}</div>
          <div className="p-4 sm:p-6">
            <div className="flex flex-wrap items-start justify-between gap-3"><div><div className="eyebrow text-[9px]">Residential collection</div><h2 className="mt-1 text-2xl font-semibold tracking-tight">{property.name}</h2><p className="muted mt-1 text-xs">⌖ {property.address || 'Address to be added'}</p></div>{canManage && <button className="btn btn-ghost text-xs" onClick={() => setEditingProperty(property)}><Icon name="edit"/> Edit details</button>}</div>
            <div className="mt-5 grid grid-cols-3 divide-x divide-[#dce9e6] rounded-2xl border border-[#e5eeeb] bg-[#f6faf9] py-3 text-center"><div><div className="text-lg font-extrabold">{property.units.length}</div><div className="text-[10px] text-[#78908a]">units</div></div><div><div className="text-lg font-extrabold">{property.units.length - occupied}</div><div className="text-[10px] text-[#78908a]">ready</div></div><div><div className="text-lg font-extrabold">{property.units.length ? Math.round(occupied / property.units.length * 100) : 0}%</div><div className="text-[10px] text-[#78908a]">managed</div></div></div>
            <div className="mt-5 flex items-center justify-between border-b border-[#e7efec] pb-3"><div><div className="text-sm font-semibold">Units <span className="ml-1 rounded-full bg-[#e5f1ec] px-1.5 py-0.5 text-[10px]">{property.units.length}</span></div><p className="muted mt-1 text-[10px]">Select a unit to view its tenant and tenancy information.</p></div>{canManage && <button className="btn btn-primary" onClick={() => setEditingUnit({ propertyId: property.id, name: '', description: '', rent: 0 })}><Icon name="plus"/> Add unit</button>}</div>
            <div className="mt-3 space-y-2">{property.units.map((unit, index) => {
              const opened = expandedUnit === unit.id; const occupiedUnit = isOccupied(unit); const tenant = unit.tenantId ? tenants.find(t => t.id === unit.tenantId) || tenantCandidates.find(t => t.id === unit.tenantId) : undefined; const tenancy = tenancies.find(t => t.unitId === unit.id && ['active', 'move_out_requested'].includes(t.status));
              return <div key={unit.id} className={`overflow-hidden rounded-xl border ${opened ? 'border-[#c6dfd1] bg-[#f6faf6]' : 'border-[#e5eeeb] bg-[#fafcfb]'}`}>
                <div className="flex items-center gap-3 p-3"><button className="flex min-w-0 flex-1 items-center gap-3 text-left" onClick={() => setExpandedUnit(opened ? '' : unit.id)} aria-expanded={opened}><span className="grid h-9 w-9 shrink-0 place-items-center rounded-lg bg-[#e5f1e7] text-[10px] font-bold text-[#276d53]">{String(index + 1).padStart(2, '0')}</span><span className="min-w-0 flex-1"><span className="block truncate text-xs font-bold">Unit {unit.name}</span><span className="muted mt-1 block truncate text-[10px]">{tenant?.name || unit.description || 'Unit details'}</span></span><span className={`hidden text-[10px] font-semibold sm:block ${occupiedUnit ? 'text-[#af790d]' : 'text-[#16814e]'}`}>● {occupiedUnit ? 'Occupied' : 'Ready'}</span><span className="px-1 text-xs text-[#627771]">{opened ? '⌃' : '⌄'}</span></button>{canManage && <div className="flex shrink-0 gap-1"><button className="grid h-8 w-8 place-items-center rounded-lg border border-[#dce9e6] bg-white" onClick={() => setEditingUnit({ id: unit.id, propertyId: property.id, name: unit.name, description: unit.description, rent: unit.rent })} title="Edit unit"><Icon name="edit"/></button>{canDelete && <button className="grid h-8 w-8 place-items-center rounded-lg border border-[#dce9e6] bg-white text-red-600" onClick={() => onDeleteUnit(unit.id)} title="Delete unit"><Icon name="trash"/></button>}</div>}</div>
                {opened && <div className="grid gap-4 border-t border-[#dce9e6] px-4 py-4 sm:grid-cols-3"><div><div className="muted text-[10px]">Unit details</div><div className="mt-1 text-xs font-semibold">{unit.description || 'No description provided'}</div><div className="muted mt-3 text-[10px]">Monthly rent</div><div className="mt-1 text-xs font-semibold">{money(unit.rent)}</div></div><div className="sm:col-span-2">
                  {occupiedUnit ? <><div className="text-[10px] font-bold uppercase tracking-wide text-[#0f766e]">Current tenant</div>{tenant ? <><div className="mt-1 text-sm font-extrabold">{tenant.name}</div><div className="mt-1 break-all text-xs">{tenant.email}</div><div className="mt-1 text-xs">{tenant.phone || 'Phone number not provided'}</div>{tenant.welfare && <div className="muted mt-2 text-[10px]">Welfare: {tenant.welfare}</div>}</> : <div className="muted mt-2 text-xs">This unit is occupied, but the tenant profile is not available in this workspace.</div>}{tenancy && <div className="mt-3 grid gap-2 border-t border-[#dce9e6] pt-3 text-xs sm:grid-cols-3"><div><div className="muted text-[10px]">Tenancy status</div><b className="mt-1 block capitalize">{tenancy.status.replaceAll('_', ' ')}</b></div><div><div className="muted text-[10px]">Start date</div><b className="mt-1 block">{tenancy.startDate || '—'}</b></div><div><div className="muted text-[10px]">Contract rent</div><b className="mt-1 block">{money(tenancy.rentAmount)}</b></div></div>}</> : <><div className="text-[10px] font-bold uppercase tracking-wide text-[#16814e]">Vacant unit</div><div className="muted mt-1 text-xs">No active tenant is assigned to this unit.</div>{canManage && <button className="btn btn-soft mt-3 text-xs" onClick={() => setAssigningUnit({ unit, propertyId: property.id })}>Assign tenant</button>}</>}
                </div></div>}
              </div>;
            })}{!property.units.length && <div className="rounded-xl bg-[#f6faf9] p-4 text-xs muted">No units have been added yet.</div>}</div>
          </div>
        </article>;
      })}
    </div>
    {editingProperty && <PropertyEditor property={editingProperty} onClose={() => setEditingProperty(undefined)} onSave={onSaveProperty}/>} 
    {editingUnit && <UnitEditor initial={editingUnit} onClose={() => setEditingUnit(undefined)} onSave={unit => unit.id ? onSaveUnit(unit) : onAddUnit(unit)}/>} 
    {assigningUnit && <TenantAssignment unit={assigningUnit.unit} tenants={candidates} defaultRent={assigningUnit.unit.rent} onClose={() => setAssigningUnit(undefined)} onAssign={(tenantId, startDate, rent) => onAssignTenant(assigningUnit.unit.id, tenantId, startDate, rent)}/>} 
  </>;
}
