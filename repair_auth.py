from pathlib import Path

p = Path(r'C:\Users\USER\Downloads\NestTrack\NestTrack\src\App.tsx')
text = p.read_text(encoding='utf-8')
start = text.index('const submitLogin=async()=>')
end = text.index('const signup=async()=>')
replacement = """const submitLogin=async()=>{const identifier=email.trim().toLowerCase();const localUser=users.find(x=>x.email.toLowerCase()===identifier && x.password===password);if(isSupabaseConfigured){try{const au=await signIn(email.trim(),password);return onLogin({id:au.id,name:au.user_metadata?.full_name||email.trim(),email:email.trim(),password:'',role:'tenant',orgId:'',welfare:'Good'} as User)}catch(e:any){if(localUser){localStorage.setItem('nesttrack-last-name',localUser.name);return onLogin(localUser);}return setError(e.message||'Incorrect email or password.')}}}if(!localUser)return setError('Incorrect email or password.');localStorage.setItem('nesttrack-last-name',localUser.name);onLogin(localUser)};\n"""
p.write_text(text[:start] + replacement + text[end:], encoding='utf-8')
print('patched')
