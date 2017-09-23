import Topic from 'discourse/models/topic';
import User from 'discourse/models/user';
import TopicStatus from 'discourse/raw-views/topic-status';
import { popupAjaxError } from 'discourse/lib/ajax-error';
import { withPluginApi } from 'discourse/lib/plugin-api';
import { ajax } from 'discourse/lib/ajax';
import PostCooked from 'discourse/widgets/post-cooked';

// function clearAccepted(topic) {
//   const posts = topic.get('postStream.posts');
//   posts.forEach(post => {
//     if (post.get('post_number') > 1 ) {
//       post.set('accepted_answer',false);
//       post.set('can_accept_answer',true);
//       post.set('can_unaccept_answer',false);
//     }
//   });
// }

function unacceptPost(post) {
  if (!post.get('can_unaccept_answer')) { return; }
  const topic = post.topic;

  post.setProperties({
    can_queue_answer: true,
    can_unaccept_answer: false,
    accepted_answer: false
  });

  const newAnswers = topic.get('accepted_answers').filter(answer => {
    return answer.post_number != post.get("post_number");
  });

  topic.set('accepted_answers', newAnswers);

  ajax("/solution/unaccept", {
    type: 'POST',
    data: { id: post.get('id') }
  }).catch(popupAjaxError);
}

// function acceptPost(post) {
//   const topic = post.topic;

//   clearAccepted(topic);

//   post.setProperties({
//     can_unaccept_answer: true,
//     can_accept_answer: false,
//     accepted_answer: true
//   });

//   topic.set('accepted_answer', {
//     username: post.get('username'),
//     post_number: post.get('post_number'),
//     excerpt: post.get('cooked'),
//   });

//   ajax("/solution/accept", {
//     type: 'POST',
//     data: { id: post.get('id') }
//   }).catch(popupAjaxError);
// }

function queueAnswer(post) {

  post.setProperties({
    can_queue_answer: false,
    is_queued_answer: "true"
  });

  ajax("/solution/queue", {
    type: 'POST',
    data: { id: post.get('id') }
  }).catch(popupAjaxError);
}

function unqueueAnswer(post) {

  post.setProperties({
    can_queue_answer: true,
    is_queued_answer: null
  });

  ajax("/solution/unqueue", {
    type: 'POST',
    data: { id: post.get('id') }
  }).catch(popupAjaxError);
}


function initializeWithApi(api) {
  const currentUser = api.getCurrentUser();

  api.includePostAttributes('can_queue_answer', 'accepted_answer', 'can_unaccept_answer', 'is_queued_answer');

  if (api.addDiscoveryQueryParam) {
    api.addDiscoveryQueryParam('solved', {replace: true, refreshModel: true});
  }

  if (currentUser) {
    ajax("/solution/is_show_link").then(result => {

      if (result.show_link) {
        api.decorateWidget('hamburger-menu:generalLinks', () => {
          return {
            route: 'adminPlugins.solutions',
            label: 'solved.menu'
          };
        });
      }
    });
  }

  api.addPostMenuButton('solved', attrs => {
    const canQueue    = attrs.can_queue_answer;
    const canUnaccept = attrs.can_unaccept_answer;
    const accepted    = attrs.accepted_answer;
    const isQueued    = attrs.is_queued_answer;

    if (canQueue) {
      return {
        action: 'queueAnswer',
        icon: 'check-square-o',
        className: 'unaccepted',
        title: 'solved.accept_answer',
        position: 'first'
      };
    } else if (canUnaccept || accepted) {
      const title = canUnaccept ? 'solved.unaccept_answer' : 'solved.accepted_answer';
      return {
        action: 'unacceptAnswer',
        icon: 'check-square',
        title,
        className: 'accepted fade-out',
        position: 'first',
        beforeButton(h) {
          return h('span.accepted-text', I18n.t('solved.solution'));
        }
      };
    } else if (isQueued == "true") {
      return {
        action: 'unqueueAnswer',
        icon: 'check-square',
        title: 'solved.accepted_answer',
        className: 'unaccepted',
        position: 'first',
        beforeButton(h) {
          return h('span.accepted-text.queued', I18n.t('solved.solution'));
        }
      };
    }

    // const canAccept = attrs.can_accept_answer;
    // const canUnaccept = attrs.can_unaccept_answer;
    // const accepted = attrs.accepted_answer;
    // const isOp = currentUser && currentUser.id === attrs.topicCreatedById;
    // const position = (!accepted && canAccept && !isOp) ? 'second-last-hidden' : 'first';

    // if (canAccept) {
    //   return {
    //     action: 'acceptAnswer',
    //     icon: 'check-square-o',
    //     className: 'unaccepted',
    //     title: 'solved.accept_answer',
    //     position
    //   };
    // } else if (canUnaccept || accepted) {
    //   const title = canUnaccept ? 'solved.unaccept_answer' : 'solved.accepted_answer';
    //   return {
    //     action: 'unacceptAnswer',
    //     icon: 'check-square',
    //     title,
    //     className: 'accepted fade-out',
    //     position,
    //     beforeButton(h) {
    //       return h('span.accepted-text', I18n.t('solved.solution'));
    //     }
    //   };
    // }
  });

  // api.decorateWidget('post-contents:before-cooked', dec => {
  //   const postModel = dec.getModel();
  //   if (postModel.accepted_answer) {
  //     return dec.h('span.accepted-text', I18n.t('solved.solution'));
  //   }
  // });

  api.decorateWidget('post-contents:after-cooked', dec => {
    // if (dec.attrs.post_number === 1) {
    //   const postModel = dec.getModel();
    //   if (postModel) {
    //     const topic = postModel.get('topic');
    //     if (topic.get('accepted_answer')) {
    //       const hasExcerpt = !!topic.get('accepted_answer').excerpt;

    //       const withExcerpt = `
    //         <aside class='quote' data-post="${topic.get('accepted_answer').post_number}" data-topic="${topic.get('id')}">
    //           <div class='title'>
    //             ${topic.get('acceptedAnswerHtml')} <div class="quote-controls"><\/div>
    //           </div>
    //           <blockquote>
    //             ${topic.get('accepted_answer').excerpt}
    //           </blockquote>
    //         </aside>`;

    //       const withoutExcerpt = `
    //         <aside class='quote'>
    //           <div class='title title-only'>
    //             ${topic.get('acceptedAnswerHtml')}
    //           </div>
    //         </aside>`;

    //       var cooked = new PostCooked({ cooked: hasExcerpt ? withExcerpt : withoutExcerpt });

    //       var html = cooked.init();

    //       return dec.rawHtml(html);
    //     }
    //   }
    // }

    if (dec.attrs.post_number === 1) {
      const postModel = dec.getModel();
      if (postModel) {
        const topic   = postModel.get('topic');
        const answers = topic.get('accepted_answers');
        if (answers) {

          const htmls = answers.map(answer => {
            const hasExcerpt = !!answer.excerpt;
            const rawHtml = topic.acceptedAnswerRawHtml(answer);

            const withExcerpt = `
              <aside class='quote' data-post="${answer.post_number}" data-topic="${topic.get('id')}">
                <div class='title'>
                  ${rawHtml} <div class="quote-controls"><\/div>
                </div>
                <blockquote>
                  ${answer.excerpt}
                </blockquote>
              </aside>`;

            const withoutExcerpt = `
              <aside class='quote'>
                <div class='title title-only'>
                  ${rawHtml}
                </div>
              </aside>`;

            return hasExcerpt ? withExcerpt : withoutExcerpt;
          });

          // const cookedHtml = dec.rawHtml(htmls);
          // console.log(htmls);
          // console.log(cookedHtml);
          let cooked = new PostCooked({ cooked: htmls.join("") });

          return dec.rawHtml(cooked.init());
        }
      }
    }
  });


  api.attachWidgetAction('post', 'queueAnswer', function() {
    const post = this.model;
    // const current = post.get('topic.postStream.posts').filter(p => {
    //   return p.get('post_number') === 1 || p.get('accepted_answer');
    // });
    queueAnswer(post);

    //current.forEach(p => this.appEvents.trigger('post-stream:refresh', { id: p.id }));
  });

  api.attachWidgetAction('post', 'unqueueAnswer', function() {
    const post = this.model;
    unqueueAnswer(post);
  });

  // api.attachWidgetAction('post', 'acceptAnswer', function() {
  //   const post = this.model;
  //   const current = post.get('topic.postStream.posts').filter(p => {
  //     return p.get('post_number') === 1 || p.get('accepted_answer');
  //   });
  //   acceptPost(post);

  //   current.forEach(p => this.appEvents.trigger('post-stream:refresh', { id: p.id }));
  // });

  api.attachWidgetAction('post', 'unacceptAnswer', function() {
    const post = this.model;
    const op = post.get('topic.postStream.posts').find(p => p.get('post_number') === 1);
    unacceptPost(post);
    this.appEvents.trigger('post-stream:refresh', { id: op.get('id') });
  });

  if (api.registerConnectorClass) {
    api.registerConnectorClass('user-activity-bottom', 'solved-list', {
      shouldRender(args, component) {
        return component.siteSettings.solved_enabled;
      },
    });
    api.registerConnectorClass('user-summary-stat', 'solved-count', {
      shouldRender(args, component) {
        return component.siteSettings.solved_enabled && args.model.solved_count > 0;
      },
      setupComponent() {
        this.set('classNames', ['linked-stat']);
      }
    });
  }
}

export default {
  name: 'extend-for-solved-button',
  initialize() {

    Topic.reopen({
      // keeping this here cause there is complex localization
      acceptedAnswerRawHtml: function(answer) {
        const username    = answer.username;
        const postNumber  = answer.post_number;

        if (!username || !postNumber) {
          return "";
        }

        return I18n.t("solved.accepted_html", {
          username_lower: username.toLowerCase(),
          username,
          post_path: this.get('url') + "/" + postNumber,
          post_number: postNumber,
          user_path: User.create({username: username}).get('path')
        });
      },
      // acceptedAnswerHtml: function() {
      //   const username = this.get('accepted_answer.username');
      //   const postNumber = this.get('accepted_answer.post_number');

      //   if (!username || !postNumber) {
      //     return "";
      //   }

      //   return I18n.t("solved.accepted_html", {
      //     username_lower: username.toLowerCase(),
      //     username,
      //     post_path: this.get('url') + "/" + postNumber,
      //     post_number: postNumber,
      //     user_path: User.create({username: username}).get('path')
      //   });
      // }.property('accepted_answers', 'id')
    });

    // TopicStatus.reopen({
    //   statuses: function(){
    //     const results = this._super();
    //     if (this.topic.has_accepted_answer) {
    //       results.push({
    //         openTag: 'span',
    //         closeTag: 'span',
    //         title: I18n.t('solved.has_accepted_answers'),
    //         icon: 'check-square-o'
    //       });
    //     } else if(this.topic.can_have_answer && this.siteSettings.solved_enabled && this.siteSettings.empty_box_on_unsolved){
    //       results.push({
    //         openTag: 'span',
    //         closeTag: 'span',
    //         title: I18n.t('solved.has_no_accepted_answers'),
    //         icon: 'square-o'
    //       });
    //     }
    //     return results;
    //   }.property()
    // });

    withPluginApi('0.1', initializeWithApi);
  }
};
