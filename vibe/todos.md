# Initial Questions
- In our current astro build, is SSR the right term to describe our server side enhancements? whats the difference between that and "islands."
- Right now our dev server just uses the standard "astro dev server" — in my understanding is that it's not optimal, but it seems to work well enough and updates really fast on change. Are ther econsiderations I am missing here?
- If we wanted the dev or static instance to "generate a static build for preview" where would be the best place to build, and serve it out of? I wouldnt mind using the caddy "web instance" but I wouldnt want to set up another domain just for the build preview. We can create more domains if needed, but maybe theres a more pragmatic option?
- In wp-save-triggered-build-queue-spec.md we specify two new services, and api and a worker, is that overkill for our needs? will a single new service do?
# Deployment dashboard
- Wordpress will only run on dev, and stating, the production environment is a static astro build with a few SSR elements 
- We have a series of scripts in /astro/site/ deploy-to-dev, deploy-to-staging, deploy-to-production
- In our abcnorio-func plugin, I want an admin menu item called "Deployment"
- In it there will be three tabs, "Dev" "Staging" and "Production"
- The Dev and Staging tabs will have the following buttons:
-- "Preview"
-- "Run Static Build"
- When "Run static build clicked, that button turns into a progress spinner (using a small svg) until the build is complete, then it adds a "preview button" inline with the "run satic build button"
- Staging will have one other button for "Deploy to production" - which would run our production deployment (which im about to describe)
- In the production tab, we should see "rebuild production" 
- And a list of the last three backups, with a "revert to this version" attached to either.
# Production Deployment
- backup production into a zip file abcnorio-production-yyyymmdd-hhmm.zip
- Run a build, on success -> copy it over production - wheres the best place to output this to?
- Do we need to restart caddy for good measure? best if avoidable
- Are there other considerations?


