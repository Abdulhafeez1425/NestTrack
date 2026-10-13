import { useEffect, useState, type ReactElement } from 'react';
import brandMark from '../assets/nesttrack-mark-128x128.png';

type LandingPageProps = { onNavigate: (path: '/login' | '/signup') => void };

const features = [
  ['Property and unit management', 'Keep properties, units, occupants, rent amounts and property-level details together.'],
  ['Rent tracking and payment visibility', 'Track current and future rent periods, payment evidence, reviews and advance payments.'],
  ['Tenant communication', 'Keep direct messages and support conversations connected to the people and places they concern.'],
  ['Maintenance coordination', 'Create, assign and update maintenance tickets while tenants, managers and technicians stay aligned.'],
  ['Tenant welfare and support', 'Organise welfare checks, support requests and important operational notes with care.'],
  ['Role-based administration', 'Give landlords, managers, tenants, technicians and admins the right level of access.'],
];

const faqs = [
  ['What is NestTrack?', 'NestTrack is a property operations platform for managing rental properties, rent visibility, communication, maintenance and support in one workspace.'],
  ['Who is NestTrack for?', 'It is designed for landlords, property managers, tenants, maintenance teams and platform administrators who need a clearer operational record.'],
  ['Can tenants submit rent payment receipts?', 'Yes. Tenants can select the rent period they are paying for, submit payment evidence and follow its review status.'],
  ['Can tenants pay rent in advance?', 'Yes. NestTrack supports selecting current or future rent periods where advance payment workflows are enabled for the workspace.'],
  ['Does NestTrack support maintenance requests?', 'Yes. Tenants can raise requests and property teams can assign, track and update maintenance work.'],
  ['How does NestTrack protect access to property information?', 'Access is organised around roles, workspace membership and database-level authorization, with controlled permissions for sensitive actions.'],
];

function MiniIcon({ kind }: { kind: string }) {
  const paths: Record<string, ReactElement> = {
    home: <><path d="m4 10 8-6 8 6"/><path d="M6 9v10h12V9"/><path d="M10 19v-5h4v5"/></>,
    card: <><rect x="3" y="5" width="18" height="14" rx="2"/><path d="M3 10h18"/><path d="M7 15h3"/></>,
    chat: <><path d="M20 11a7.5 7.5 0 0 1-8 7.5 8.5 8.5 0 0 1-4-.9L4 19l1.4-3.6A7.5 7.5 0 1 1 20 11Z"/></>,
    wrench: <><path d="M14.7 6.3a4 4 0 0 0-5.2 5.2L4 17l3 3 5.5-5.5a4 4 0 0 0 5.2-5.2l-2.6 2.6-2.3-2.3Z"/></>,
  };
  return <svg aria-hidden="true" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">{paths[kind] || paths.home}</svg>;
}

function Brand({ compact = false }: { compact?: boolean }) {
  return <a href="/" className={`landing-brand ${compact ? 'landing-brand-compact' : ''}`} aria-label="NestTrack home"><img src={brandMark} alt="" /> <span>NestTrack</span></a>;
}

export default function LandingPage({ onNavigate }: LandingPageProps) {
  const [menuOpen, setMenuOpen] = useState(false);
  const [openFaq, setOpenFaq] = useState<number | null>(null);

  useEffect(() => {
    document.title = 'NestTrack | Property Operations, Rent Tracking and Tenant Communication';
    const description = 'NestTrack brings property operations, rent tracking, tenant communication and maintenance coordination into one clear workspace.';
    let meta = document.querySelector('meta[name="description"]') as HTMLMetaElement | null;
    if (!meta) { meta = document.createElement('meta'); meta.name = 'description'; document.head.appendChild(meta); }
    meta.content = description;
    let canonical = document.querySelector('link[rel="canonical"]') as HTMLLinkElement | null;
    if (!canonical) { canonical = document.createElement('link'); canonical.rel = 'canonical'; document.head.appendChild(canonical); }
    canonical.href = window.location.origin + '/';
    const structuredData = { '@context': 'https://schema.org', '@graph': [
      { '@type': 'Organization', name: 'NestTrack', url: window.location.origin, logo: `${window.location.origin}/assets/nesttrack-app-icon-180x180.png` },
      { '@type': 'SoftwareApplication', name: 'NestTrack', applicationCategory: 'BusinessApplication', operatingSystem: 'Web', description },
      { '@type': 'FAQPage', mainEntity: faqs.map(([question, answer]) => ({ '@type': 'Question', name: question, acceptedAnswer: { '@type': 'Answer', text: answer } })) },
    ] };
    let jsonLd = document.getElementById('nesttrack-landing-schema') as HTMLScriptElement | null;
    if (!jsonLd) { jsonLd = document.createElement('script'); jsonLd.id = 'nesttrack-landing-schema'; jsonLd.type = 'application/ld+json'; document.head.appendChild(jsonLd); }
    jsonLd.textContent = JSON.stringify(structuredData);
    return () => { jsonLd?.remove(); };
  }, []);

  const go = (path: '/login' | '/signup') => { setMenuOpen(false); onNavigate(path); };
  return <div className="landing-page">
    <header className="landing-header"><div className="landing-container landing-header-inner"><Brand /><nav className={`landing-nav ${menuOpen ? 'is-open' : ''}`} aria-label="Primary navigation">
      <a href="#features" onClick={() => setMenuOpen(false)}>Features</a><a href="#how-it-works" onClick={() => setMenuOpen(false)}>How it works</a><a href="#audiences" onClick={() => setMenuOpen(false)}>For teams</a><a href="#faq" onClick={() => setMenuOpen(false)}>FAQ</a>
      <div className="landing-nav-actions"><button className="landing-link-button" onClick={() => go('/login')}>Sign in</button><button className="landing-button landing-button-small" onClick={() => go('/signup')}>Get started</button></div>
    </nav><button className="landing-menu-button" aria-expanded={menuOpen} aria-controls="landing-navigation" aria-label={menuOpen ? 'Close menu' : 'Open menu'} onClick={() => setMenuOpen(!menuOpen)}><span/><span/><span/></button></div></header>

    <main>
      <section className="landing-hero"><div className="landing-container landing-hero-grid"><div className="landing-hero-copy"><div className="landing-kicker"><span className="landing-kicker-dot"/> Property operations, made clearer</div><h1>Property operations, <em>organized</em> in one place.</h1><p className="landing-lead">NestTrack helps landlords, managers, tenants and maintenance teams manage properties, rent, repairs, communication and records with less friction and more visibility.</p><div className="landing-hero-actions"><button className="landing-button" onClick={() => go('/signup')}>Get started <span>→</span></button><a className="landing-text-link" href="#features">Explore features <span>↓</span></a></div><p className="landing-note">Already have an account? <button onClick={() => go('/login')}>Sign in</button></p></div>
        <div className="landing-hero-visual" aria-label="NestTrack workspace preview"><div className="landing-orbit landing-orbit-one"/><div className="landing-orbit landing-orbit-two"/><div className="landing-dashboard-card"><div className="landing-window-bar"><span/><span/><span/><b>Workspace overview</b><i>•••</i></div><div className="landing-dashboard-body"><div className="landing-preview-sidebar"><div className="landing-preview-logo"><img src={brandMark} alt=""/></div><span className="active"/><span/><span/><span/><span/></div><div className="landing-preview-content"><div className="landing-preview-heading"><div><small>LANDLORD OVERVIEW</small><strong>Good morning, Ada</strong></div><div className="landing-preview-avatar">AO</div></div><div className="landing-preview-stats"><div><small>Properties</small><b>03</b><span>12 total units</span></div><div><small>Occupancy</small><b>83%</b><span>10 occupied</span></div><div><small>Collected</small><b>₦2.4m</b><span>Paid rent in view</span></div></div><div className="landing-preview-panels"><div className="landing-preview-panel"><div className="panel-title">Portfolio <span>View all</span></div><div className="preview-row"><div className="preview-house"/><div><b>Maple Court</b><small>4/4 occupied</small></div><mark>Active</mark></div><div className="preview-row"><div className="preview-house house-two"/><div><b>Riverside Place</b><small>6/8 occupied</small></div><mark>Active</mark></div></div><div className="landing-preview-panel preview-priority"><div className="panel-title">Priority today</div><div className="priority-line"><span className="priority-dot amber"/><div><b>Payment review</b><small>2 receipts awaiting review</small></div></div><div className="priority-line"><span className="priority-dot coral"/><div><b>Maintenance</b><small>1 high priority request</small></div></div></div></div></div></div></div><div className="landing-float-card landing-float-payment"><span className="landing-float-icon"><MiniIcon kind="card"/></span><span><b>Rent visibility</b><small>Payment evidence tracked</small></span><strong>✓</strong></div><div className="landing-float-card landing-float-message"><span className="landing-float-icon"><MiniIcon kind="chat"/></span><span><b>Team aligned</b><small>New tenant message</small></span></div></div>
      </div></section>

      <section className="landing-value-strip"><div className="landing-container landing-value-grid"><div><strong>One workspace</strong><span>for every property conversation</span></div><div><strong>Clear rent visibility</strong><span>from due date to review</span></div><div><strong>Faster coordination</strong><span>for repairs and requests</span></div><div><strong>Role-aware access</strong><span>built into each workspace</span></div></div></section>

      <section className="landing-section landing-section-light" id="features"><div className="landing-container"><div className="landing-section-intro"><div className="landing-kicker">Everything connected</div><h2>The operational details, <em>in view.</em></h2><p>From the first rent record to the final maintenance update, NestTrack keeps the work that matters easy to find and easy to act on.</p></div><div className="landing-feature-grid">{features.map(([title, text], i) => <article className="landing-feature-card" key={title}><div className="landing-feature-number">0{i + 1}</div><div className="landing-feature-icon"><MiniIcon kind={['home', 'card', 'chat', 'wrench', 'chat', 'home'][i]}/></div><h3>{title}</h3><p>{text}</p><a href="#how-it-works">See how it works <span>↗</span></a></article>)}</div></div></section>

      <section className="landing-section landing-how" id="how-it-works"><div className="landing-container"><div className="landing-how-grid"><div className="landing-section-intro"><div className="landing-kicker">A practical flow</div><h2>Move from scattered tasks to <em>shared context.</em></h2><p>Set up the workspace once, then give each person a clear place to manage the work in front of them.</p><button className="landing-button landing-button-dark" onClick={() => go('/signup')}>Create your workspace <span>→</span></button></div><div className="landing-steps"><div><span>01</span><div><h3>Create or join a workspace</h3><p>Start with the organization and people who need to work together.</p></div></div><div><span>02</span><div><h3>Add your property details</h3><p>Bring properties, units, tenants and operational information into view.</p></div></div><div><span>03</span><div><h3>Keep daily work aligned</h3><p>Track rent, maintenance, messages and support with clear notifications and records.</p></div></div></div></div></div></section>

      <section className="landing-section landing-audiences" id="audiences"><div className="landing-container"><div className="landing-section-intro centered"><div className="landing-kicker">Built around real roles</div><h2>A clearer day for <em>every team.</em></h2><p>Each role gets the visibility and actions they need without adding noise for everyone else.</p></div><div className="landing-audience-grid"><article><div className="audience-label">For landlords & managers</div><h3>See the portfolio. Follow through.</h3><p>Monitor property operations, review rent evidence, coordinate maintenance and keep reliable records across the team.</p><a href="#features">Explore for property teams <span>→</span></a></article><article><div className="audience-label">For tenants</div><h3>Know what happens next.</h3><p>View rent information, submit receipts, select payment periods, contact support and follow maintenance requests.</p><a href="#features">Explore for tenants <span>→</span></a></article><article><div className="audience-label">For maintenance teams</div><h3>Work with the right context.</h3><p>Receive assigned tickets, share updates, record quotes or evidence and keep property teams informed.</p><a href="#features">Explore for technicians <span>→</span></a></article></div></div></section>

      <section className="landing-section landing-preview-section"><div className="landing-container landing-preview-grid"><div className="landing-section-intro"><div className="landing-kicker">A workspace that speaks plainly</div><h2>Less hunting. More <em>moving forward.</em></h2><p>Representative views for the work NestTrack helps you keep in one place: rent ledger, payment review, maintenance, messages and property overview.</p><div className="landing-preview-list"><span><i><MiniIcon kind="card"/></i>Rent ledger & payment evidence</span><span><i><MiniIcon kind="wrench"/></i>Maintenance tickets & updates</span><span><i><MiniIcon kind="chat"/></i>Messages & support conversations</span></div></div><div className="landing-interface-stack"><div className="stack-card stack-back"><small>PROPERTY OVERVIEW</small><strong>Riverside Place</strong><span>8 units · 6 occupied</span></div><div className="stack-card stack-front"><div className="stack-card-top"><span>PAYMENT REVIEW</span><b>Needs attention</b></div><div className="stack-payment"><div className="stack-avatar">KO</div><div><strong>October rent receipt</strong><span>Submitted by Kemi Okafor</span></div><em>Review</em></div><div className="stack-line"><span/><span/><span/></div><div className="stack-card-bottom"><span>Payment period</span><b>October 2026</b><span>Amount</span><b>₦180,000</b></div></div></div></div></section>

      <section className="landing-section landing-security"><div className="landing-container landing-security-grid"><div><div className="landing-kicker">Trust in the details</div><h2>Visibility with the right <em>boundaries.</em></h2></div><div className="landing-security-copy"><p>NestTrack is designed around practical access control and operational clarity, not broad claims. Sensitive actions stay with the roles and workspace members responsible for them.</p><div className="security-points"><span>Role-based access</span><span>Database-level authorization</span><span>Controlled payment reviews</span><span>Audit-friendly history</span></div></div></div></section>

      <section className="landing-section landing-faq" id="faq"><div className="landing-container landing-faq-grid"><div className="landing-section-intro"><div className="landing-kicker">Questions, answered</div><h2>Good to know <em>before you start.</em></h2><p>Start with the essentials. Your workspace can grow with the way your team operates.</p><button className="landing-text-link" onClick={() => go('/signup')}>Get started with NestTrack <span>→</span></button></div><div className="landing-accordion">{faqs.map(([question, answer], i) => <div className={`landing-faq-item ${openFaq === i ? 'open' : ''}`} key={question}><button aria-expanded={openFaq === i} onClick={() => setOpenFaq(openFaq === i ? null : i)}><span>{question}</span><b>+</b></button>{openFaq === i && <p>{answer}</p>}</div>)}</div></div></section>

      <section className="landing-final-cta"><div className="landing-container landing-final-inner"><div><div className="landing-kicker">Bring it into focus</div><h2>Property operations that feel <em>under control.</em></h2><p>Give your team one clear place to manage the work behind every home.</p></div><div className="landing-final-actions"><button className="landing-button landing-button-light" onClick={() => go('/signup')}>Get started <span>→</span></button><button className="landing-outline-button" onClick={() => go('/login')}>Sign in</button></div></div></section>
    </main>
    <footer className="landing-footer"><div className="landing-container landing-footer-grid"><div><Brand compact/><p>Property operations, organized in one place.</p></div><div className="landing-footer-links"><div><strong>Product</strong><a href="#features">Features</a><a href="#how-it-works">How it works</a><a href="#faq">FAQ</a></div><div><strong>Access</strong><button onClick={() => go('/login')}>Sign in</button><button onClick={() => go('/signup')}>Get started</button><a href="mailto:support@nesttrack.app">Contact support</a></div></div></div><div className="landing-container landing-footer-bottom"><span>© {new Date().getFullYear()} NestTrack</span><span>Secure, role-aware property operations</span></div></footer>
  </div>;
}
