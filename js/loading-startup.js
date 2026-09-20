(() => {
      const screen = document.getElementById('psmStartupLoading');
      const status = document.getElementById('psmLoadingStatus');
      const tip = document.getElementById('psmLoadingTipText');
      const tips = [
        'お気に入りの曲を見つけて、あなただけのスコアリストを作りましょう！',
        '同期後はPSR保存履歴から、過去の数値や順位変化をいつでも見返せます。',
        '曲カードをタップすると、ライバルとの比較をすばやく確認できます。'
      ];
      let finished = false;
      let tipIndex = 0;
      const tipTimer = window.setInterval(() => {
        if (finished) return;
        tipIndex = (tipIndex + 1) % tips.length;
        tip.textContent = tips[tipIndex];
      }, 4600);
      const timeout = window.setTimeout(() => {
        if (finished) return;
        screen.classList.add('is-stalled');
        status.textContent = '読み込みに時間がかかっています。通信状況をご確認ください。';
      }, 20000);
      document.getElementById('psmLoadingRetry').addEventListener('click', () => window.location.reload());
      window.psmLoading = {
        status(message) {
          if (finished) return;
          if (message) status.textContent = message;
        },
        finish() {
          if (finished) return;
          finished = true;
          clearTimeout(timeout);
          clearInterval(tipTimer);
          status.textContent = '準備ができました';
          window.setTimeout(() => { screen.hidden = true; }, 180);
        },
        error(error) {
          if (finished) return;
          clearTimeout(timeout);
          clearInterval(tipTimer);
          screen.classList.add('is-stalled');
          status.textContent = '読み込みに失敗しました：' + (error?.message || String(error || '原因不明')) + '。再読み込みしてください。';
        }
      };
    })();
