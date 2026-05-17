// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

// https://astro.build/config
export default defineConfig({
  site: 'https://docs.deepsql.ai',
  integrations: [
    starlight({
      title: 'DeepSQL Docs',
      description:
        'Self-host DeepSQL — install, configure, and operate the stack in your VPC.',
      favicon: '/favicon.svg',
      customCss: ['./src/styles/custom.css'],
      social: [
        {
          icon: 'github',
          label: 'GitHub',
          href: 'https://github.com/DeepSQLAI/deepsql-self-host',
        },
      ],
      editLink: {
        baseUrl: 'https://github.com/DeepSQLAI/deepsql-self-host/edit/main/docs/',
      },
      sidebar: [
        {
          label: 'Get Started',
          items: [
            { label: 'Overview', slug: 'index' },
            { label: 'Quickstart', slug: 'quickstart' },
            { label: 'Prerequisites', slug: 'prerequisites' },
          ],
        },
        {
          label: 'Install',
          items: [
            { label: 'What install.sh does', slug: 'install/script-walkthrough' },
            { label: 'Environment variables', slug: 'install/env-vars' },
            { label: 'MCP & coding agents', slug: 'install/mcp-agents' },
            { label: 'Upgrade', slug: 'install/upgrade' },
            { label: 'Uninstall', slug: 'install/uninstall' },
          ],
        },
        {
          label: 'Deploy on AWS',
          items: [
            { label: 'CloudFormation (one-click)', slug: 'aws/cloudformation' },
            { label: 'Networking & Aurora/RDS access', slug: 'aws/networking' },
            { label: 'SSM access for support', slug: 'aws/support-access' },
          ],
        },
        {
          label: 'Operations',
          items: [
            { label: 'Status & smoke test', slug: 'ops/status' },
            { label: 'Logs', slug: 'ops/logs' },
            { label: 'Diagnostic bundle', slug: 'ops/diagnose' },
            { label: 'Troubleshooting', slug: 'ops/troubleshooting' },
          ],
        },
        {
          label: 'Release notes',
          link: 'https://github.com/DeepSQLAI/deepsql-self-host/releases',
          attrs: { target: '_blank', rel: 'noopener' },
        },
      ],
    }),
  ],
});
