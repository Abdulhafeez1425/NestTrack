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

type Tenant = {
  id: string;
  name: string;
  email: string;
  phone?: string;
  welfare?: string;
};

type Tenancy = {
  id: string;
  unitId: string;
  tenantId: string;
  startDate?: string;
  endDate?: string;
  rentAmount: number;
  status: string;
};

type PropertyDraft = {
  id?: string;
  name: string;
  address: string;
  image: string;
  units: PropertyUnit[];
};

type UnitDraft = {
  id?: string;
  propertyId: string;
  name: string;
  description: string;
  rent: number;
};

const money = (amount: number) => `₦${amount.toLocaleString()}`;
const isOccupied = (unit: PropertyUnit) => Boolean(unit.tenantId) || unit.status === 'occupied';

export function PropertyEditor({
  property,
  onClose,
  onSave,
}: {
  property?: ManagedProperty;
  onClose: () => void;
  onSave: (draft: PropertyDraft, imageFile?: File) => Promise<void>;
}) {
  const [name, setName] = useState(property?.name || '');
  const [address, setAddress] = useState(property?.address || '');
  const [image, setImage] = useState(property?.image || '');
  const [imageFile, setImageFile] = useState<File>();
  const [units, setUnits] = useState<PropertyUnit[]>(property?.units.map(unit => ({ ...unit })) || [
    { id: 'new-unit', name: '', description: '', rent: 0 },
  ]);
  const [preview, setPreview] = useState<string>();
  const [error, setError] = useState('');
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    if (!imageFile) {
      setPreview(undefined);
      return;
    }
    const url = URL.createObjectURL(imageFile);
    setPreview(url);
    return () => URL.revokeObjectURL(url);
  }, [imageFile]);

  const updateUnit = (index: number, changes: Partial<PropertyUnit>) => {
    setUnits(current => current.map((unit, unitIndex) =>
      unitIndex === index ? { ...unit, ...changes } : unit,
    ));
  };

  const submit = async (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    setError('');
    if (!name.trim() || !address.trim()) {
      setError('Enter a property name and address.');
      return;
    }
    if (!property && (!units.length || units.some(unit => !unit.name.trim()))) {
      setError('Give every unit a name before creating the property.');
      return;
    }
    if (units.some(unit => unit.rent < 0 || !Number.isFinite(unit.rent))) {
      setError('Unit rent must be zero or greater.');
      return;
    }
    setSaving(true);
    try {
      await onSave({ id: property?.id, name: name.trim(), address: address.trim(), image, units }, imageFile);
      onClose();
    } catch (saveError) {
      setError(saveError instanceof Error ? saveError.message : 'Property could not be saved.');
    } finally {
      setSaving(false);
    }
  };

  return (
    <div className="fixed inset-0 z-[60] grid place-items-center overflow-y-auto bg-[#0b2927aa] p-3 sm:p-6" onMouseDown={event => {
      if (event.target === event.currentTarget && !saving) onClose();
    }}>
      <form onSubmit={submit} className="my-auto w-full max-w-3xl overflow-hidden rounded-2xl bg-white shadow-2xl">
        <div className="flex items-start justify-between border-b border-[#e5eeeb] px-5 py-4 sm:px-7">
          <div>
            <div className="eyebrow">Property portfolio</div>
            <h2 className="mt-1 text-xl font-extrabold">{property ? 'Edit property' : 'Add property'}</h2>
            <p className="muted mt-1 text-xs">Property details, image and spaces in one place.</p>
          </div>
          <button type="button" onClick={onClose} aria-label="Close property form" className="rounded-lg px-3 py-2 text-lg text-[#536963] hover:bg-[#f3f8f6]">×</button>
        </div>

        <div className="grid max-h-[75vh] gap-5 overflow-y-auto p-5 sm:p-7">
          <section className="grid gap-4 md:grid-cols-2">
            <label className="block text-xs font-bold">Property name
              <input className="input mt-1.5" required value={name} onChange={event => setName(event.target.value)} placeholder="e.g. JIZBO Apartments" />
            </label>
            <label className="block text-xs font-bold">Address
              <input className="input mt-1.5" required value={address} onChange={event => setAddress(event.target.value)} placeholder="Street, area, city" />
            </label>
          </section>

          <section>
            <div className="mb-2 text-xs font-bold">Property image</div>
            <div className="overflow-hidden rounded-xl border border-dashed border-[#b9d2ca] bg-[#f6faf9]">
              {preview || image ? (
                <img src={preview || image} alt="Property preview" className="h-44 w-full object-cover sm:h-56" />
              ) : (
                <div className="grid h-36 place-items-center px-5 text-center text-sm muted">Choose an image to preview it here. No demo image will be substituted.</div>
              )}
              <div className="grid gap-3 border-t border-[#e5eeeb] bg-white p-3 sm:grid-cols-[1fr_2fr]">
                <label className="flex cursor-pointer items-center justify-center rounded-lg border border-[#dce9e6] px-3 py-2.5 text-xs font-bold text-[#195b4e] hover:bg-[#f6faf9]">
                  {imageFile?.name || 'Choose image'}
                  <input className="sr-only" type="file" accept="image/jpeg,image/png,image/webp,image/gif" onChange={event => {
                    const file = event.target.files?.[0];
                    if (!file) return;
                    if (!file.type.startsWith('image/')) {
                      setError('Choose an image file.');
                      return;
                    }
                    if (file.size > 10 * 1024 * 1024) {
                      setError('Property images must be 10 MB or smaller.');
                      return;
                    }
                    setError('');
                    setImageFile(file);
                    setImage('');
                  }} />
                </label>
                <input className="input text-xs" type="url" value={imageFile ? '' : image} onChange={event => {
                  setImage(event.target.value);
                  setImageFile(undefined);
                }} placeholder="Or paste an image URL" aria-label="Property image URL" />
              </div>
            </div>
          </section>

          {!property && <section>
            <div className="mb-3 flex items-center justify-between">
              <div>
                <h3 className="text-sm font-extrabold">Units</h3>
                <p className="muted mt-1 text-xs">Add the spaces that belong to this property.</p>
              </div>
              <button type="button" className="btn btn-soft" onClick={() => setUnits(current => [
                ...current,
                { id: `new-unit-${current.length + 1}`, name: '', description: '', rent: 0 },
              ])}>+ Add unit</button>
            </div>
            <div className="space-y-2">
              {units.map((unit, index) => <div key={unit.id} className="grid gap-2 rounded-xl bg-[#f6faf9] p-3 md:grid-cols-[1fr_1.5fr_1fr_auto]">
                <input className="input" value={unit.name} onChange={event => updateUnit(index, { name: event.target.value })} placeholder="Unit name" aria-label={`Unit ${index + 1} name`} />
                <input className="input" value={unit.description} onChange={event => updateUnit(index, { description: event.target.value })} placeholder="Description" aria-label={`Unit ${index + 1} description`} />
                <input className="input" type="number" min="0" value={unit.rent || ''} onChange={event => updateUnit(index, { rent: Number(event.target.value) })} placeholder="Monthly rent" aria-label={`Unit ${index + 1} rent`} />
                {units.length > 1 && <button type="button" className="rounded-lg px-2 text-sm text-red-600 hover:bg-red-50" onClick={() => setUnits(current => current.filter((_, unitIndex) => unitIndex !== index))} aria-label={`Remove unit ${index + 1}`}>Remove</button>}
              </div>)}
            </div>
          </section>}

          {error && <div role="alert" className="rounded-xl bg-[#fff0ef] p-3 text-sm text-[#b42318]">{error}</div>}
        </div>
        <div className="flex justify-end gap-2 border-t border-[#e5eeeb] px-5 py-4 sm:px-7">
          <button type="button" className="btn btn-ghost" disabled={saving} onClick={onClose}>Cancel</button>
          <button type="submit" className="btn btn-primary" disabled={saving}>{saving ? 'Saving…' : property ? 'Save changes' : 'Create property'}</button>
        </div>
      </form>
    </div>
  );
}

function UnitEditor({
  initial,
  onClose,
  onSave,
}: {
  initial: UnitDraft;
  onClose: () => void;
  onSave: (unit: UnitDraft) => Promise<void>;
}) {
  const [name, setName] = useState(initial.name);
  const [description, setDescription] = useState(initial.description);
  const [rent, setRent] = useState(String(initial.rent || ''));
  const [error, setError] = useState('');
  const [saving, setSaving] = useState(false);
  return <div className="fixed inset-0 z-[70] grid place-items-center bg-[#0b2927aa] p-4">
    <form className="w-full max-w-md rounded-2xl bg-white p-6 shadow-2xl" onSubmit={async event => {
      event.preventDefault();
      if (!name.trim() || Number(rent) < 0) {
        setError('Enter a unit name and a non-negative rent amount.');
        return;
      }
      setSaving(true);
      setError('');
      try {
        await onSave({ ...initial, name: name.trim(), description: description.trim(), rent: Number(rent) });
        onClose();
      } catch (saveError) {
        setError(saveError instanceof Error ? saveError.message : 'Unit could not be saved.');
      } finally {
        setSaving(false);
      }
    }}>
      <div className="eyebrow">Property unit</div>
      <h2 className="mt-1 text-lg font-extrabold">{initial.id ? 'Edit unit' : 'Add unit'}</h2>
      <label className="mt-4 block text-xs font-bold">Unit name<input className="input mt-1" value={name} onChange={event => setName(event.target.value)} required /></label>
      <label className="mt-3 block text-xs font-bold">Description<input className="input mt-1" value={description} onChange={event => setDescription(event.target.value)} placeholder="Bedrooms, floor or features" /></label>
      <label className="mt-3 block text-xs font-bold">Monthly rent<input className="input mt-1" type="number" min="0" value={rent} onChange={event => setRent(event.target.value)} required /></label>
      {error && <div role="alert" className="mt-3 rounded-xl bg-[#fff0ef] p-3 text-sm text-[#b42318]">{error}</div>}
      <div className="mt-5 flex justify-end gap-2"><button type="button" className="btn btn-ghost" disabled={saving} onClick={onClose}>Cancel</button><button type="submit" className="btn btn-primary" disabled={saving}>{saving ? 'Saving…' : 'Save unit'}</button></div>
    </form>
  </div>;
}

export function PropertyCollection({
  properties,
  tenants,
  tenancies,
  canManage,
  canDelete,
  onAdd,
  onSaveProperty,
  onAddUnit,
  onSaveUnit,
  onDeleteProperty,
  onDeleteUnit,
}: {
  properties: ManagedProperty[];
  tenants: Tenant[];
  tenancies: Tenancy[];
  canManage: boolean;
  canDelete: boolean;
  onAdd: () => void;
  onSaveProperty: (draft: PropertyDraft, imageFile?: File) => Promise<void>;
  onAddUnit: (unit: UnitDraft) => Promise<void>;
  onSaveUnit: (unit: UnitDraft) => Promise<void>;
  onDeleteProperty: (id: string) => void;
  onDeleteUnit: (id: string) => void;
}) {
  const [expandedUnit, setExpandedUnit] = useState('');
  const [editingProperty, setEditingProperty] = useState<ManagedProperty>();
  const [editingUnit, setEditingUnit] = useState<UnitDraft>();
  const unitCount = properties.reduce((count, property) => count + property.units.length, 0);
  const occupiedCount = properties.reduce((count, property) => count + property.units.filter(isOccupied).length, 0);

  return <>
    <div className="mb-6 flex flex-wrap items-end justify-between gap-4">
      <div><div className="eyebrow">Portfolio</div><h1 className="mt-1 text-3xl font-extrabold tracking-tight">Properties</h1><p className="muted mt-1 text-sm">Buildings, units and their current tenancy details.</p></div>
      {canManage && <button className="btn btn-primary" onClick={onAdd}>+ Add property</button>}
    </div>
    {!properties.length && <div className="card p-8 text-center"><div className="font-extrabold">No properties yet</div><p className="muted mt-2 text-sm">Create your first property and add its units.</p>{canManage && <button className="btn btn-primary mt-4" onClick={onAdd}>Add property</button>}</div>}
    <div className="space-y-6">
      {properties.map(property => {
        const occupied = property.units.filter(isOccupied).length;
        return <article key={property.id} className="overflow-hidden rounded-[20px] border border-[#dce9e6] bg-white shadow-sm">
          <div className="relative h-48 bg-[#e7efec] sm:h-64">
            {property.image && <img src={property.image} alt={property.name} className="h-full w-full object-cover" />}
            <span className="absolute left-4 top-4 rounded-full bg-[#173c35]/90 px-3 py-1 text-[10px] font-bold text-white">● Active listing</span>
            {canManage && <div className="absolute right-4 top-4 flex gap-2">
              <button className="rounded-lg bg-white/95 px-3 py-2 text-sm font-semibold text-[#174d43] shadow" onClick={() => setEditingProperty(property)} aria-label={`Edit ${property.name}`}>Edit</button>
              {canDelete && <button className="rounded-lg bg-white/95 px-3 py-2 text-sm font-semibold text-red-700 shadow" onClick={() => onDeleteProperty(property.id)} aria-label={`Delete ${property.name}`}>Delete</button>}
            </div>}
            <span className="absolute bottom-4 left-4 rounded bg-[#0b2927]/65 px-2 py-1 text-[10px] font-bold text-white">PROPERTY</span>
          </div>
          <div className="p-4 sm:p-6">
            <div className="flex flex-wrap items-start justify-between gap-3">
              <div><div className="eyebrow text-[9px]">Residential collection</div><h2 className="mt-1 text-2xl font-semibold tracking-tight">{property.name}</h2><p className="muted mt-1 text-xs">⌖ {property.address || 'Address to be added'}</p></div>
              {canManage && <button className="btn btn-ghost text-xs" onClick={() => setEditingProperty(property)}>Edit details</button>}
            </div>
            <div className="mt-5 grid grid-cols-3 divide-x divide-[#dce9e6] rounded-xl border border-[#e5eeeb] bg-[#f6faf9] py-3 text-center">
              <div><div className="text-lg font-extrabold">{unitCount === 0 ? 0 : property.units.length}</div><div className="muted text-[10px]">units</div></div>
              <div><div className="text-lg font-extrabold">{property.units.length - occupied}</div><div className="muted text-[10px]">ready</div></div>
              <div><div className="text-lg font-extrabold">{property.units.length ? Math.round(occupied / property.units.length * 100) : 0}%</div><div className="muted text-[10px]">managed</div></div>
            </div>
            <div className="mt-5 flex items-center justify-between border-b border-[#e7efec] pb-3">
              <div><div className="text-sm font-semibold">Units <span className="ml-1 rounded-full bg-[#e5f1ec] px-1.5 py-0.5 text-[10px]">{property.units.length}</span></div><p className="muted mt-1 text-[10px]">Select an occupied unit to view tenant and tenancy information.</p></div>
              {canManage && <button className="btn btn-primary" onClick={() => setEditingUnit({ propertyId: property.id, name: '', description: '', rent: 0 })}>+ Add unit</button>}
            </div>
            <div className="mt-3 space-y-2">
              {property.units.map((unit, index) => {
                const opened = expandedUnit === unit.id;
                const occupiedUnit = isOccupied(unit);
                const tenant = unit.tenantId ? tenants.find(person => person.id === unit.tenantId) : undefined;
                const tenancy = tenancies.find(item => item.unitId === unit.id && ['active', 'move_out_requested'].includes(item.status));
                return <div key={unit.id} className={`overflow-hidden rounded-xl border ${opened ? 'border-[#c6dfd1] bg-[#f6faf6]' : 'border-[#e5eeeb] bg-[#fafcfb]'}`}>
                  <div className="flex items-center gap-3 p-3">
                    <button className="flex min-w-0 flex-1 items-center gap-3 text-left" onClick={() => setExpandedUnit(opened ? '' : unit.id)} aria-expanded={opened}>
                      <span className="grid h-9 w-9 shrink-0 place-items-center rounded-lg bg-[#e5f1e7] text-[10px] font-bold text-[#276d53]">{String(index + 1).padStart(2, '0')}</span>
                      <span className="min-w-0 flex-1"><span className="block truncate text-xs font-bold">Unit {unit.name}</span><span className="muted mt-1 block truncate text-[10px]">{tenant?.name || unit.description || 'Unit details'}</span></span>
                      <span className={`hidden text-[10px] font-semibold sm:block ${occupiedUnit ? 'text-[#af790d]' : 'text-[#16814e]'}`}>● {occupiedUnit ? 'Occupied' : 'Ready'}</span>
                      <span className="px-1 text-xs text-[#627771]">{opened ? '⌃' : '⌄'}</span>
                    </button>
                    {canManage && <div className="flex shrink-0 gap-1">
                      <button className="rounded-lg border border-[#dce9e6] bg-white px-2 py-1.5 text-[10px] font-semibold" onClick={() => setEditingUnit({ id: unit.id, propertyId: property.id, name: unit.name, description: unit.description, rent: unit.rent })}>Edit</button>
                      {canDelete && <button className="rounded-lg border border-[#dce9e6] bg-white px-2 py-1.5 text-[10px] font-semibold text-red-600" onClick={() => onDeleteUnit(unit.id)}>Delete</button>}
                    </div>}
                  </div>
                  {opened && <div className="grid gap-4 border-t border-[#dce9e6] px-4 py-4 sm:grid-cols-3">
                    <div><div className="muted text-[10px]">Unit details</div><div className="mt-1 text-xs font-semibold">{unit.description || 'No description provided'}</div><div className="muted mt-3 text-[10px]">Monthly rent</div><div className="mt-1 text-xs font-semibold">{money(unit.rent)}</div></div>
                    {occupiedUnit ? <div className="sm:col-span-2">
                      <div className="text-[10px] font-bold uppercase tracking-wide text-[#0f766e]">Current tenant</div>
                      {tenant ? <>
                        <div className="mt-1 text-sm font-extrabold">{tenant.name}</div>
                        <div className="mt-1 break-all text-xs">{tenant.email}</div>
                        <div className="mt-1 text-xs">{tenant.phone || 'Phone number not provided'}</div>
                        {tenant.welfare && <div className="muted mt-2 text-[10px]">Welfare: {tenant.welfare}</div>}
                      </> : <div className="muted mt-2 text-xs">This unit is marked occupied, but its tenant profile is not available in this workspace.</div>}
                      {tenancy && <div className="mt-3 grid gap-2 border-t border-[#dce9e6] pt-3 text-xs sm:grid-cols-3">
                        <div><div className="muted text-[10px]">Tenancy status</div><b className="mt-1 block capitalize">{tenancy.status.replaceAll('_', ' ')}</b></div>
                        <div><div className="muted text-[10px]">Start date</div><b className="mt-1 block">{tenancy.startDate || '—'}</b></div>
                        <div><div className="muted text-[10px]">Contract rent</div><b className="mt-1 block">{money(tenancy.rentAmount)}</b></div>
                      </div>}
                    </div> : <div className="sm:col-span-2"><div className="text-[10px] font-bold uppercase tracking-wide text-[#16814e]">Vacant unit</div><div className="muted mt-1 text-xs">No active tenant is assigned to this unit.</div></div>}
                  </div>}
                </div>;
              })}
              {!property.units.length && <div className="rounded-xl bg-[#f6faf9] p-4 text-xs muted">No units have been added yet.</div>}
            </div>
          </div>
        </article>;
      })}
    </div>
    {editingProperty && <PropertyEditor property={editingProperty} onClose={() => setEditingProperty(undefined)} onSave={onSaveProperty} />}
    {editingUnit && <UnitEditor initial={editingUnit} onClose={() => setEditingUnit(undefined)} onSave={unit => unit.id ? onSaveUnit(unit) : onAddUnit(unit)} />}
  </>;
}
