import { type ReactElement } from 'react';
import privacyPolicy from '../../docs/PRIVACY_POLICY.md?raw';
import termsAndConditions from '../../docs/TERMS_AND_CONDITIONS.md?raw';

export type LegalDocument = 'privacy' | 'terms';

type LegalPageProps = { document: LegalDocument };

function inlineMarkdown(value: string) {
  const escaped = value.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
  return escaped
    .replace(/\[([^\]]+)\]\(([^)]+)\)/g, '<a href="$2" class="text-[#0f766e] underline underline-offset-2 hover:text-[#0b625c">$1</a>')
    .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
    .replace(/`([^`]+)`/g, '<code class="rounded bg-[#eef6f3] px-1.5 py-0.5 text-[.9em] text-[#315850]">$1</code>');
}

function MarkdownContent({ source }: { source: string }) {
  const lines = source.replaceAll('\r\n', '\n').split('\n');
  const blocks: ReactElement[] = [];
  let paragraph: string[] = [];
  let list: string[] = [];

  const flushParagraph = () => {
    if (!paragraph.length) return;
    blocks.push(<p key={`p-${blocks.length}`} className="mt-4 leading-7 text-[#5f746f]" dangerouslySetInnerHTML={{ __html: inlineMarkdown(paragraph.join(' ')) }} />);
    paragraph = [];
  };
  const flushList = () => {
    if (!list.length) return;
    blocks.push(<ul key={`ul-${blocks.length}`} className="mt-4 list-disc space-y-2 pl-6 leading-7 text-[#5f746f]">{list.map((item, index) => <li key={`${item}-${index}`} dangerouslySetInnerHTML={{ __html: inlineMarkdown(item) }} />)}</ul>);
    list = [];
  };

  lines.forEach((line, index) => {
    const trimmed = line.trim();
    if (!trimmed) { flushParagraph(); flushList(); return; }
    if (trimmed.startsWith('# ')) { flushParagraph(); flushList(); blocks.push(<h1 key={`h1-${index}`} className="mt-2 text-3xl font-extrabold tracking-[-0.04em] text-[#173634] sm:text-4xl">{trimmed.slice(2)}</h1>); return; }
    if (trimmed.startsWith('## ')) { flushParagraph(); flushList(); blocks.push(<h2 key={`h2-${index}`} className="mt-12 border-t border-[#e3eeeb] pt-8 text-2xl font-extrabold tracking-[-0.035em] text-[#173634]">{trimmed.slice(3)}</h2>); return; }
    if (trimmed.startsWith('### ')) { flushParagraph(); flushList(); blocks.push(<h3 key={`h3-${index}`} className="mt-8 text-lg font-extrabold text-[#173634]">{trimmed.slice(4)}</h3>); return; }
    if (trimmed.startsWith('- ')) { flushParagraph(); list.push(trimmed.slice(2)); return; }
    if (/^\d+\. /.test(trimmed)) { flushParagraph(); list.push(trimmed.replace(/^\d+\. /, '')); return; }
    if (trimmed.startsWith('> ')) { flushParagraph(); flushList(); blocks.push(<blockquote key={`quote-${index}`} className="mt-5 border-l-4 border-[#0f766e] bg-[#eef8f5] px-5 py-4 leading-7 text-[#4e6962]" dangerouslySetInnerHTML={{ __html: inlineMarkdown(trimmed.slice(2)) }} />); return; }
    paragraph.push(trimmed);
  });
  flushParagraph(); flushList();
  return <>{blocks}</>;
}

export default function LegalPage({ document }: LegalPageProps) {
  const isPrivacy = document === 'privacy';
  const source = isPrivacy ? privacyPolicy : termsAndConditions;
  const title = isPrivacy ? 'Privacy Policy' : 'Terms and Conditions';
  const eyebrow = isPrivacy ? 'Your information, explained' : 'Using NestTrack responsibly';

  return <div className="min-h-screen bg-[#f5faf8] text-[#173634]">
    <header className="sticky top-0 z-20 border-b border-[#dce9e6]/80 bg-[#f5faf8]/90 backdrop-blur-xl">
      <div className="mx-auto flex h-[72px] w-[min(1160px,calc(100%-32px))] items-center justify-between gap-4">
        <a href="/" className="flex items-center gap-2.5 text-lg font-extrabold tracking-[-0.055em] text-[#0b2927]" aria-label="NestTrack home"><span className="grid h-9 w-9 place-items-center rounded-xl bg-[#d9f6ef] text-sm font-black text-[#0f766e]">N</span><span>NestTrack</span></a>
        <div className="flex items-center gap-2 sm:gap-4"><a href="/" className="hidden text-xs font-bold text-[#58706b] hover:text-[#0f766e] sm:inline">Back to home</a><a href="/login" className="rounded-lg border border-[#c8ddd8] bg-white px-3 py-2 text-xs font-bold text-[#315850] hover:border-[#86bdb0] hover:text-[#0f766e]">Sign in</a></div>
      </div>
    </header>
    <main className="mx-auto grid w-[min(1160px,calc(100%-32px))] gap-8 py-10 lg:grid-cols-[220px_minmax(0,760px)] lg:gap-16 lg:py-16">
      <aside className="hidden lg:block"><div className="sticky top-28 rounded-2xl border border-[#dce9e6] bg-white p-5 shadow-[0_6px_20px_rgba(16,42,42,.035)]"><div className="text-[10px] font-extrabold uppercase tracking-[.14em] text-[#0f766e]">NestTrack legal</div><div className="mt-4 space-y-2 text-xs font-semibold text-[#718580]"><a href="/legal/privacy-policy" className={`block rounded-lg px-3 py-2 hover:bg-[#eff8f5] hover:text-[#0f766e] ${isPrivacy ? 'bg-[#eff8f5] text-[#0f766e]' : ''}`}>Privacy Policy</a><a href="/legal/terms-and-conditions" className={`block rounded-lg px-3 py-2 hover:bg-[#eff8f5] hover:text-[#0f766e] ${!isPrivacy ? 'bg-[#eff8f5] text-[#0f766e]' : ''}`}>Terms and Conditions</a></div></div></aside>
      <article className="min-w-0 rounded-2xl border border-[#dce9e6] bg-white px-5 py-7 shadow-[0_12px_32px_rgba(16,42,42,.05)] sm:px-8 sm:py-10 lg:px-12"><div className="mb-8 border-b border-[#e3eeeb] pb-7"><div className="text-[10px] font-extrabold uppercase tracking-[.15em] text-[#0f766e]">{eyebrow}</div><div className="mt-3"><MarkdownContent source={source.split('\n\n').slice(0, 1).join('\n\n')} /></div><p className="mt-4 text-sm leading-6 text-[#718580]">Please review this draft with qualified legal counsel before publishing or relying on it for a production service.</p></div><MarkdownContent source={source.split('\n\n').slice(2).join('\n\n')} /></article>
    </main>
    <footer className="border-t border-[#dce9e6] bg-white"><div className="mx-auto flex w-[min(1160px,calc(100%-32px))] flex-col gap-2 py-6 text-xs text-[#81918d] sm:flex-row sm:items-center sm:justify-between"><span>© {new Date().getFullYear()} NestTrack</span><span>Role-aware property operations</span></div></footer>
  </div>;
}
